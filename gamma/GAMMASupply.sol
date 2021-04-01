pragma solidity 0.5.8;

import "./ITRC20.sol";
import "./TRC20.sol";
import "./GAMMAToken.sol";
import "./Ownable.sol";
import './TransferHelper.sol';
import './Rank.sol';
import './IRefer.sol';
import './Refer.sol';

////////////////////////////////////////////
//    ┏┓   ┏┓
//   ┏┛┻━━━┛┻┓
//   ┃       ┃
//   ┃   ━   ┃
//   ┃ ＞   ＜  ┃
//   ┃       ┃
//   ┃    . ⌒ .. ┃
//   ┃       ┃
//   ┗━┓   ┏━┛
//     ┃   ┃ Codes are far away from bugs
//     ┃   ┃ with the animal protecting
//     ┃   ┃
//     ┃   ┃
//     ┃   ┃
//     ┃   ┃
//     ┃   ┗━━━┓
//     ┃       ┣┓
//     ┃       ┏┛
//     ┗┓┓┏━┳┓┏┛
//      ┃┫┫ ┃┫┫
//      ┗┻┛ ┗┻┛
////////////////////////////////////////////

contract GAMMASupply is Ownable, Rank {
    using SafeMath for uint256;

    struct winner {
        address addr;
        bool isWinner;
    }

    struct Record {
        address addr; // 被推荐人地址
        uint256 amount; // 奖励的USDT数量
    }

    struct SystemSetting {
        uint256 round;  // 当前轮次
        uint256 layers; // 当前层数
        uint256 limitPerLayer; // 当前轮每一层开放的GSC购买额度
        uint256 price; // 初始价格，放大100倍，方便整数计算
        uint256 curLeftOver; // 当前层剩余的GSC额度
    }

    // 事件
    event ForgeLow(address indexed user, uint256 usdtAmount);
    event ForgeMedium(address indexed user, uint256 usdtAmount);
    event ForgeHigh(address indexed user, uint256 usdtAmount);

    event ForgeLowSuccess(address indexed user, uint256 gscAmount);
    event ForgeMediumSuccess(address indexed user, uint256 gscAmount);
    event ForgeHighSuccess(address indexed user, uint256 gscAmount);

    event ForgeLowFail(address indexed user, uint256 usdtRefund);
    event ForgeMediumFail(address indexed user, uint256 usdtRefund);
    event ForgeHighFail(address indexed user, uint256 usdtRefund);

    bool flagInitialized = false; // 参数是否初始化？初始化一次

    // The GSC token
    GAMMAToken public gsc;   // GSC token合约地址
    address public usdt;  // USDT token合约地址
    // Dev address.
    address public devaddr;  // 提现USDT地址

    uint256 public startBlock; // 当前轮开始的区块高度

    Refer public refer;
    mapping (address => Record[]) public referRecord; // 推荐奖励记录
    uint256 public totalReferBonus; // 全网推荐总收益

    // 系统参数
    SystemSetting public setting;

    // 不同层的差价
    uint256[] public priceDeltas = [5, 1, 2, 3, 4, 5, 6, 7, 8, 9];

    // 最少需要投入1 GSC
    uint256 public constant MIN_GSC_REQUIRE = 1e6;

    // 每层增加10000 GSC额度
    uint256 public constant LAYER_DELTA = 10000e6;
//    uint256 public constant LAYER_DELTA = 1000e6; //测试用，每层增加1000

    // 最大轮数限制
    uint256 public constant TOTAL_ROUND = 10;
    // 最大层数限制
    uint256 public constant TOTAL_LAYERS = 10;
    // 9 人一组开奖
    uint256 public constant GROUP_NUM_LIMIT = 9;
    // 一组开奖3人
    uint256 public constant GROUP_WIN_NUM = 3;

    uint256 public constant USDTAmountLow = 100e6;
    uint256 public constant USDTAmountMedium = 500e6;
    uint256 public constant USDTAmountHigh = 1000e6;

    winner[] public winnersLow;
    winner[] public winnersMedium;
    winner[] public winnersHigh;


    struct winAmount {
        uint256 gscAmount;
        uint256 usdtAmount;
    }

    // 保存熔炼成功获得的GSC数量
    mapping (address => winAmount) public forgeWinAmount;

    // 奖励赛奖金池，前三轮资金的20%
    uint256 public racePoolTotalAmount = 0;

    // 当季新增资金量
    uint256 public increasedTotalAmount = 0;

    // 用于计算链上随机数
    uint256 nonce = 0;

    // 奖励赛TOP K
    uint256 public constant RANK_TOP_NUM = 20;

    // 奖励赛前20名奖励的百分比，放大1000倍
    uint256[] bonusRate = [300, 200, 100, 80, 70, 60, 50, 40, 30, 20, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5];

    // constructor
    constructor (
        GAMMAToken _gsc,
        address _usdt,
        address _devaddr,
        Refer _refer
    ) public {
        gsc = _gsc;
        usdt = _usdt;
        devaddr = _devaddr;
        refer = _refer;
    }

    // 设置初始参数
    function setParams(uint256 _startBlock) public onlyOwner {
        require(!flagInitialized, "setParams only call once");
        flagInitialized = true;

        startBlock = _startBlock;
        // 设置系统参数 (round, layers, limitPerLayer, price, curLeftOver)
        setting = SystemSetting(1, 1, 50000e6, 10, 50000e6);

        // 测试用
//        setting = SystemSetting(1, 1, 10000e6, 10, 10000e6);
    }

    // 产生一个[0 - 8]的随机数
    function winnerNumber() internal returns(uint256) {
        uint256 win = uint256(keccak256(abi.encodePacked(now, msg.sender, nonce))) % GROUP_NUM_LIMIT;
        nonce++;
        return win;
    }

    // 系统只运行在每天的[20 - 21]点
    function requireSystemActive() internal view {
        uint256 startHour = 12;
        uint256 endHour = 13;
        uint256 hour = now % (1 days) / (1 hours);
        require(hour >= startHour && hour <= endHour, "system only works in [20 - 21] hour!");
    }

    // 判断是否要进入下一层/轮
    function enterNextLayer() internal returns (bool) {
        bool flagRaceBegin = false;
        setting.layers = setting.layers.add(1);
        if (setting.layers > TOTAL_LAYERS) {

            // 当前轮已超过10层，进入下一轮，轮数加1
            setting.round = setting.round.add(1);
            setting.layers = 1;

            if (setting.round > 3) {
                flagRaceBegin = true; // 从第4轮开始，开始计算熔炼奖励赛
            }
        }

        // 下一层增加1万额度，同时把上一层剩余的累加上去
        setting.limitPerLayer = setting.limitPerLayer.add(LAYER_DELTA).add(setting.curLeftOver);
        setting.curLeftOver = setting.limitPerLayer;
        setting.price = setting.price.add(priceDeltas[setting.round.sub(1)]);

        return flagRaceBegin;
    }

    // 获取熔炼成功的GSC数量
    function getForgeWinAmount (address usr) public view returns (uint256 gscAmount, uint256 usdtAmount) {
        gscAmount =  forgeWinAmount[usr].gscAmount;
        usdtAmount = forgeWinAmount[usr].usdtAmount;
    }

    // 参与初级熔炼
    function forgeLow(address referrer) public {
        requireSystemActive();
        require(block.number >= startBlock, "next round not yet started");
        require(gsc.balanceOf(msg.sender) >= MIN_GSC_REQUIRE, "at least 1 GSC required");

        // 如果额度不足，则进入下一层
        bool flagRaceBegin = false;
        uint256 gscAmount = USDTAmountLow.mul(100).div(setting.price);
        if (setting.curLeftOver < gscAmount.mul(GROUP_WIN_NUM))  {
            // 如果剩余额度不足一组，则额度累加到下一层
            flagRaceBegin = enterNextLayer();// 返回值为是否进入了奖励赛
            gscAmount = USDTAmountLow.mul(100).div(setting.price);
        }

        // 最多10轮
        require(setting.round <= TOTAL_ROUND, "total 10 round finisehd");
        // 最多10层
        require(setting.layers <= TOTAL_LAYERS, "current round finished");

        // 扣除 1 GSC
        TransferHelper.safeTransferFrom(address(gsc), msg.sender, address(this), MIN_GSC_REQUIRE);
        // 扣除初级熔炼需要的USDT, 数量为 USDTAmountLow
        TransferHelper.safeTransferFrom(usdt, msg.sender, address(this), USDTAmountLow);

        //  取前三轮的20%累积到资金池 racePoolTotalAmount
        if (setting.layers <= 3) {
            racePoolTotalAmount = racePoolTotalAmount.add(USDTAmountLow.div(5));
        }

        // 当前轮新增资金量
        increasedTotalAmount = increasedTotalAmount.add(USDTAmountLow);

        // 记录推荐关系
        refer.submitRefer(msg.sender, referrer);

        // 存储并计算熔炼成功者
        if (winnersLow.length < GROUP_NUM_LIMIT) {
            winnersLow.push(winner(msg.sender, false));
        }
        if (winnersLow.length == GROUP_NUM_LIMIT) {
            // 计算出GROUP_WIN_NUM名熔炼成功者
            uint256 count = 0;
            while (count < GROUP_WIN_NUM) {
                // 计算出一个随机index, 范围[0 - 8]
                uint256 idx = winnerNumber();
                winner storage win = winnersLow[idx];
                if (!win.isWinner) {
                    win.isWinner = true;
                    count = count.add(1);
                }
            }

            // 开奖
            for (uint256 i = 0; i < winnersLow.length; i++) {
                winner storage win = winnersLow[i];
                uint256 c = 0; // 给GROUP_WIN_NUM名中奖者开奖
                if (win.isWinner && c < GROUP_WIN_NUM) {
                    // 熔炼成功
                    // 发送GSC
                    gsc.transfer(win.addr, gscAmount);
                    forgeWinAmount[win.addr].gscAmount = forgeWinAmount[win.addr].gscAmount.add(gscAmount);
                    forgeWinAmount[win.addr].usdtAmount = forgeWinAmount[win.addr].usdtAmount.add(USDTAmountLow);

                    // 更新帐户GSC排名
                    uint256 rankBalance = getRankBalance(win.addr);
                    updateRank(win.addr, rankBalance.add(gscAmount));
                    setting.curLeftOver = setting.curLeftOver.sub(gscAmount);
                    c++;

                    // 记录推荐奖励额度
                    // 推荐人获得5%
                    address refAddr = refer.getReferrer(win.addr);
                    Record memory record = Record(win.addr, USDTAmountLow.div(20));
                    referRecord[refAddr].push(record);

                    totalReferBonus = totalReferBonus.add(USDTAmountLow.div(20));

                    // 推荐人奖励5%
                    TransferHelper.safeTransfer(usdt, refAddr, USDTAmountLow.div(20));

                    // 事件
                    emit ForgeLowSuccess(win.addr, gscAmount);
                } else {
                    // 熔炼失败
                    // 退还110%
                    uint256 amount = USDTAmountLow.add(USDTAmountLow.div(10));
                    TransferHelper.safeTransfer(usdt, win.addr, amount);

                    // 记录推荐奖励额度
                    // 推荐人获得1%
                    address refAddr = refer.getReferrer(win.addr);
                    Record memory record = Record(win.addr, USDTAmountLow.div(100));
                    referRecord[refAddr].push(record);

                    totalReferBonus = totalReferBonus.add(USDTAmountLow.div(100));

                    // 推荐人奖励1%
                    TransferHelper.safeTransfer(usdt, refAddr, USDTAmountLow.div(100));

                    emit ForgeLowFail(win.addr, amount);
                }
            }
            delete winnersLow;
        }

        // 结算奖励赛
        if (flagRaceBegin) {
            // 奖励池总量 = 当前轮新增资金的20% + 第[1-3]轮累积资金的 1/7 * 20%
            uint256 totalBonus = getBonus();
            // TODO: 取排名前20的，奖励GSC
            // 第1-10名，分别为 30%-20%-10%-8%-7%-6%-5%-4%-3%-2%
            // 第11-20名各0.5%
            address[] memory topList = getTopRank();
            distributeBonus(topList, totalBonus);

            // 当前轮奖励寒结束，重置当前轮新增资金量
            increasedTotalAmount = 0;
        }

        emit ForgeLow(msg.sender, USDTAmountLow);
    }

    // 为TOP K分发奖励
    function distributeBonus(address[] memory topList, uint256 totalBonus) internal {
        require(topList.length <= bonusRate.length, "topList above RANK_TOP_NUM");

        for (uint256 i = 0; i < topList.length; i++) {
            uint256 bonus = totalBonus.div(bonusRate[i]);
            TransferHelper.safeTransfer(usdt, topList[i], bonus);
        }
    }

    // 奖励池
    function getBonus() public view returns (uint256) {
        return racePoolTotalAmount.div(7).add(increasedTotalAmount.div(5));
    }

    // 获取奖励赛TOP K, 初级
    function getTopRank() public view returns (address[] memory) {
        return getTop(RANK_TOP_NUM);
    }

    // 获取指定地址的熔炼赛排名
    function getUserRank(address usr) public view returns (uint256) {
        return getRank(usr);
    }

    // 查询推荐记录总数量
    function getReferLength(address usr) public view returns (uint256) {
        return referRecord[usr].length;
    }

    // 查询推荐的总收益
    function getReferBonus(address usr) public view returns (uint256) {
        uint256 bonus = 0;
        for (uint256 i = 0; i < referRecord[usr].length; i++) {
            bonus = bonus.add(referRecord[usr][i].amount);
        }
        return bonus;
    }

    // 查询初级熔炼池未成团人数
    function getWinnersLowLength() public view returns (uint256) {
        return winnersLow.length;
    }

    // 查询中级熔炼池未成团人数
    function getWinnersMediumLength() public view returns (uint256) {
        return winnersMedium.length;
    }

    // 查询高级熔炼池未成团人数
    function getWinnersHighLength() public view returns (uint256) {
        return winnersHigh.length;
    }

    // 查询在三个熔炼池中成团情况
    function getPendingForge(address usr) public view returns (bool low, bool medium,bool high) {
        low = false;
        medium = false;
        high = false;

        // low
        for (uint256 i = 0; i < winnersLow.length; i++) {
            if (usr == winnersLow[i].addr) {
                low = true;
                break;
            }
        }
        // medium
        for (uint256 i = 0; i < winnersMedium.length; i++) {
            if (usr == winnersMedium[i].addr) {
                medium = true;
                break;
            }
        }
        // high
        for (uint256 i = 0; i < winnersHigh.length; i++) {
            if (usr == winnersHigh[i].addr) {
                high = true;
                break;
            }
        }
    }

    function forgeMedium(address referrer) public {
        requireSystemActive();
        require(block.number >= startBlock, "next round not yet started");
        require(gsc.balanceOf(msg.sender) >= MIN_GSC_REQUIRE, "at least 1 GSC required");

        // 如果额度不足，则进入下一层
        bool flagRaceBegin = false;
        uint256 gscAmount = USDTAmountMedium.mul(100).div(setting.price);
        if (setting.curLeftOver < gscAmount.mul(GROUP_WIN_NUM))  {
            // 如果剩余额度不足一组，则额度累加到下一层
            flagRaceBegin = enterNextLayer();// 返回值为是否进入了奖励赛
            gscAmount = USDTAmountMedium.mul(100).div(setting.price);
        }

        // 最多10轮
        require(setting.round <= TOTAL_ROUND, "total 10 round finisehd");
        // 最多10层
        require(setting.layers <= TOTAL_LAYERS, "current round finished");

        // 扣除 1 GSC
        TransferHelper.safeTransferFrom(address(gsc), msg.sender, address(this), MIN_GSC_REQUIRE);
        // 扣除中级熔炼需要的USDT, 数量为 USDTAmountMedium
        TransferHelper.safeTransferFrom(usdt, msg.sender, address(this), USDTAmountMedium);

        //  取前三轮的20%累积到资金池 racePoolTotalAmount
        if (setting.layers <= 3) {
            racePoolTotalAmount = racePoolTotalAmount.add(USDTAmountMedium.div(5));
        }

        // 当前轮新增资金量
        increasedTotalAmount = increasedTotalAmount.add(USDTAmountMedium);

        // 记录推荐关系
        refer.submitRefer(msg.sender, referrer);

        // 存储并计算熔炼成功者
        if (winnersMedium.length < GROUP_NUM_LIMIT) {
            winnersMedium.push(winner(msg.sender, false));
        }
        if (winnersMedium.length == GROUP_NUM_LIMIT) {
            // 计算出GROUP_WIN_NUM名熔炼成功者
            uint256 count = 0;
            while (count < GROUP_WIN_NUM) {
                // 计算出一个随机index, 范围[0 - 8]
                uint256 idx = winnerNumber();
                winner storage win = winnersMedium[idx];
                if (!win.isWinner) {
                    win.isWinner = true;
                    count = count.add(1);
                }
            }

            // 开奖
            for (uint256 i = 0; i < winnersMedium.length; i++) {
                winner storage win = winnersMedium[i];
                uint256 c = 0; // 给GROUP_WIN_NUM名中奖者开奖
                if (win.isWinner && c < GROUP_WIN_NUM) {
                    // 熔炼成功
                    // 发送GSC
                    gsc.transfer(win.addr, gscAmount);
                    forgeWinAmount[win.addr].gscAmount = forgeWinAmount[win.addr].gscAmount.add(gscAmount);
                    forgeWinAmount[win.addr].usdtAmount = forgeWinAmount[win.addr].usdtAmount.add(USDTAmountMedium);

                    // 更新帐户GSC排名
                    uint256 rankBalance = getRankBalance(win.addr);
                    updateRank(win.addr, rankBalance.add(gscAmount));
                    setting.curLeftOver = setting.curLeftOver.sub(gscAmount);
                    c++;

                    // 记录推荐奖励额度
                    // 推荐人获得5%
                    address refAddr = refer.getReferrer(win.addr);
                    Record memory record = Record(win.addr, USDTAmountMedium.div(20));
                    referRecord[refAddr].push(record);

                    totalReferBonus = totalReferBonus.add(USDTAmountMedium.div(20));

                    // 推荐人奖励5%
                    TransferHelper.safeTransfer(usdt, refAddr, USDTAmountMedium.div(20));

                    // 事件
                    emit ForgeMediumSuccess(win.addr, gscAmount);
                } else {
                    // 熔炼失败
                    // 退还110%
                    uint256 amount = USDTAmountMedium.add(USDTAmountMedium.div(10));
                    TransferHelper.safeTransfer(usdt, win.addr, amount);

                    // 记录推荐奖励额度
                    // 推荐人获得1%
                    address refAddr = refer.getReferrer(win.addr);
                    Record memory record = Record(win.addr, USDTAmountMedium.div(100));
                    referRecord[refAddr].push(record);

                    totalReferBonus = totalReferBonus.add(USDTAmountMedium.div(100));

                    // 推荐人奖励1%
                    TransferHelper.safeTransfer(usdt, refAddr, USDTAmountMedium.div(100));

                    emit ForgeMediumFail(win.addr, amount);
                }
            }
            delete winnersMedium;
        }

        // 结算奖励赛
        if (flagRaceBegin) {
            // 奖励池总量 = 当前轮新增资金的20% + 第[1-3]轮累积资金的 1/7 * 20%
            uint256 totalBonus = getBonus();
            // TODO: 取排名前20的，奖励GSC
            // 第1-10名，分别为 30%-20%-10%-8%-7%-6%-5%-4%-3%-2%
            // 第11-20名各0.5%
            address[] memory topList = getTopRank();
            distributeBonus(topList, totalBonus);

            // 当前轮奖励寒结束，重置当前轮新增资金量
            increasedTotalAmount = 0;
        }

        emit ForgeMedium(msg.sender, USDTAmountMedium);
    }

    function forgeHigh(address referrer) public {
        requireSystemActive();
        require(block.number >= startBlock, "next round not yet started");
        require(gsc.balanceOf(msg.sender) >= MIN_GSC_REQUIRE, "at least 1 GSC required");

        // 如果额度不足，则进入下一层
        bool flagRaceBegin = false;
        uint256 gscAmount = USDTAmountHigh.mul(100).div(setting.price);
        if (setting.curLeftOver < gscAmount.mul(GROUP_WIN_NUM))  {
            // 如果剩余额度不足一组，则额度累加到下一层
            flagRaceBegin = enterNextLayer();// 返回值为是否进入了奖励赛
            gscAmount = USDTAmountHigh.mul(100).div(setting.price);
        }

        // 最多10轮
        require(setting.round <= TOTAL_ROUND, "total 10 round finisehd");
        // 最多10层
        require(setting.layers <= TOTAL_LAYERS, "current round finished");

        // 扣除 1 GSC
        TransferHelper.safeTransferFrom(address(gsc), msg.sender, address(this), MIN_GSC_REQUIRE);
        // 扣除高级熔炼需要的USDT, 数量为 USDTAmountHigh
        TransferHelper.safeTransferFrom(usdt, msg.sender, address(this), USDTAmountHigh);

        //  取前三轮的20%累积到资金池 racePoolTotalAmount
        if (setting.layers <= 3) {
            racePoolTotalAmount = racePoolTotalAmount.add(USDTAmountHigh.div(5));
        }

        // 当前轮新增资金量
        increasedTotalAmount = increasedTotalAmount.add(USDTAmountHigh);

        // 记录推荐关系
        refer.submitRefer(msg.sender, referrer);

        // 存储并计算熔炼成功者
        if (winnersHigh.length < GROUP_NUM_LIMIT) {
            winnersHigh.push(winner(msg.sender, false));
        }
        if (winnersHigh.length == GROUP_NUM_LIMIT) {
            // 计算出GROUP_WIN_NUM名熔炼成功者
            uint256 count = 0;
            while (count < GROUP_WIN_NUM) {
                // 计算出一个随机index, 范围[0 - 8]
                uint256 idx = winnerNumber();
                winner storage win = winnersHigh[idx];
                if (!win.isWinner) {
                    win.isWinner = true;
                    count = count.add(1);
                }
            }

            // 开奖
            for (uint256 i = 0; i < winnersHigh.length; i++) {
                winner storage win = winnersHigh[i];
                uint256 c = 0; // 给GROUP_WIN_NUM名中奖者开奖
                if (win.isWinner && c < GROUP_WIN_NUM) {
                    // 熔炼成功
                    // 发送GSC
                    gsc.transfer(win.addr, gscAmount);
                    forgeWinAmount[win.addr].gscAmount = forgeWinAmount[win.addr].gscAmount.add(gscAmount);
                    forgeWinAmount[win.addr].usdtAmount = forgeWinAmount[win.addr].usdtAmount.add(USDTAmountHigh);

                    // 更新帐户GSC排名
                    uint256 rankBalance = getRankBalance(win.addr);
                    updateRank(win.addr, rankBalance.add(gscAmount));
                    setting.curLeftOver = setting.curLeftOver.sub(gscAmount);
                    c++;

                    // 记录推荐奖励额度
                    // 推荐人获得5%
                    address refAddr = refer.getReferrer(win.addr);
                    Record memory record = Record(win.addr, USDTAmountHigh.div(20));
                    referRecord[refAddr].push(record);

                    totalReferBonus = totalReferBonus.add(USDTAmountHigh.div(20));

                    // 推荐人奖励5%
                    TransferHelper.safeTransfer(usdt, refAddr, USDTAmountHigh.div(20));

                    // 事件
                    emit ForgeHighSuccess(win.addr, gscAmount);
                } else {
                    // 熔炼失败
                    // 退还110%
                    uint256 amount = USDTAmountHigh.add(USDTAmountHigh.div(10));
                    TransferHelper.safeTransfer(usdt, win.addr, amount);

                    // 记录推荐奖励额度
                    // 推荐人获得1%
                    address refAddr = refer.getReferrer(win.addr);
                    Record memory record = Record(win.addr, USDTAmountHigh.div(100));
                    referRecord[refAddr].push(record);

                    totalReferBonus = totalReferBonus.add(USDTAmountHigh.div(100));

                    // 推荐人奖励1%
                    TransferHelper.safeTransfer(usdt, refAddr, USDTAmountHigh.div(100));

                    emit ForgeHighFail(win.addr, amount);
                }
            }
            delete winnersHigh;
        }

        // 结算奖励赛
        if (flagRaceBegin) {
            // 奖励池总量 = 当前轮新增资金的20% + 第[1-3]轮累积资金的 1/7 * 20%
            uint256 totalBonus = getBonus();
            // TODO: 取排名前20的，奖励GSC
            // 第1-10名，分别为 30%-20%-10%-8%-7%-6%-5%-4%-3%-2%
            // 第11-20名各0.5%
            address[] memory topList = getTopRank();
            distributeBonus(topList, totalBonus);

            // 当前轮奖励寒结束，重置当前轮新增资金量
            increasedTotalAmount = 0;
        }

        emit ForgeHigh(msg.sender, USDTAmountHigh);
    }

    // 查询推荐人地址
    function getReferrer(address usr) public view returns (address) {
        return refer.getReferrer(usr);
    }

    // 查询推荐的总人数
    function getReferrerLength(address referrer) public view returns (uint256) {
        return refer.getReferLength(referrer);
    }

    // 提取USDT
    function withdrawUSDT(uint256 amount) public returns (bool) {
        require(msg.sender == devaddr, "dev: only devaddr");
        TransferHelper.safeTransferFrom(usdt, address(this), msg.sender, amount);
        return true;
    }
}
