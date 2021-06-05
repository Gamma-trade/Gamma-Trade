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

    struct SystemSetting {
        uint256 round;  // 当前轮次
        uint256 layers; // 当前层数
        uint256 limitPerLayer; // 当前轮每一层开放的GAMMA购买额度
        uint256 price; // 初始价格，放大100倍，方便整数计算
        uint256 curLeftOver; // 当前层剩余的GAMMA额度
    }

    // The GAMMA token
    address public gamma;   // GAMMA token合约地址
    address public oldGamma;
    uint256 public reflectPercent = 5;

    address public usdt;  // USDT token合约地址
    // Dev address.
    address public devaddr;  // 提现USDT地址

    uint256 public startBlock; // 当前轮开始的区块高度

    Refer public refer;
    uint256 public totalReferBonus; // 全网推荐总收益

    mapping(address => uint256) referBonus;

    // 系统参数
    SystemSetting public setting;

    // 不同层的差价
    uint256[] public priceDeltas = [5, 1, 2, 3, 4, 5, 6, 7, 8, 9];

    // 最少需要投入1 GAMMA
    uint256 public constant MIN_GAMMA_REQUIRE = 1e6;

    // 每层增加10000 GAMMA额度
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

    address[] public winnersLow;
    address[] public winnersMedium;
    address[] public winnersHigh;

    struct winAmount {
        uint256 gammaAmount;
        uint256 usdtAmount;
    }

    // 保存熔炼成功获得的GAMMA数量
    mapping (address => winAmount) public forgeWinAmount;

    // 用于计算链上随机数
    uint256 nonce = 0;

    // 当季新增资金量
    uint256 public increasedTotalAmount = 0;

    // 奖励赛奖金池，前三轮资金的20%
    uint256 public racePoolTotalAmount = 0;

    // 奖励赛前20名奖励的百分比，放大1000倍
    uint256[] bonusRate = [300, 200, 100, 80, 70, 60, 50, 40, 30, 20, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5];
    uint256 public constant RANK_TOP_NUM = 20;

    // 奖励赛前20名
    address[] public topRank;

    // constructor
    constructor (
        address _gamma,
        address _oldGamma,
        address _usdt,
        address _devaddr,
        Refer _refer
    ) public {
        gamma = _gamma;
        oldGamma = _oldGamma;
        usdt = _usdt;
        devaddr = _devaddr;
        refer = _refer;
    }

    // set init params
    function setParams(uint256 _startBlock) public onlyOwner {
        startBlock = _startBlock;
        // 设置系统参数 (round, layers, limitPerLayer, price, curLeftOver)
        setting = SystemSetting(1, 1, 50000e6, 10, 50000e6);

//        setting = SystemSetting(1, 1, 10000e6, 10, 10000e6);
    }

    // set system setting
    function setSystemSetting(uint256 _round, uint256 _layers, uint256 _limitPerLayer, uint256 _price, uint256 _curLeftOver) public onlyOwner {
        setting = SystemSetting(_round, _layers, _limitPerLayer, _price, _curLeftOver);
    }

    function setReflectPercent(uint256 _percent) public onlyOwner {
        require(_percent < 100, "percent too large");
        reflectPercent = _percent;
    }

    function reflect() public returns (bool) {
        address sender = msg.sender;
        uint256 balance = ITRC20(oldGamma).balanceOf(sender);
        uint256 amount = balance.add(balance.mul(reflectPercent).div(100));
        TransferHelper.safeTransferFrom(oldGamma, sender, devaddr, balance);
        TransferHelper.safeTransferFrom(gamma, devaddr, sender, amount);
        return true;
    }

    // 产生一个[0 - 8]的随机数
    function winnerNumber(uint256 N) internal returns (uint256, uint256, uint256) {
        uint256 base = now;
        uint256 a = base.add(nonce++).mod(N);
        uint256 b = base.add(nonce++).mod(N);
        uint256 c = base.add(nonce++).mod(N);
        return (a, b, c);
    }

    // 系统只运行在每天的[20 - 21]点
    function requireSystemActive() internal view {
//        require(block.number >= startBlock, "next round not yet started");
        uint256 startHour = 12;
        uint256 endHour = 13;
        uint256 hour = now % (1 days) / (1 hours);
        require(hour >= startHour && hour <= endHour, "system only works in [20 - 21] hour!");
    }

    function enterNextLayer() internal {
        setting.layers = setting.layers.add(1);
        if (setting.layers > TOTAL_LAYERS) {
            // 当前轮已超过10层，进入下一轮，轮数加1
            setting.round = setting.round.add(1);
            setting.layers = 1;

            increasedTotalAmount = 0;
        }

        // 下一层增加1万额度，同时把上一层剩余的累加上去
        setting.limitPerLayer = setting.limitPerLayer.add(LAYER_DELTA).add(setting.curLeftOver);
        setting.curLeftOver = setting.limitPerLayer;
        setting.price = setting.price.add(priceDeltas[setting.round.sub(1)]);
    }

    // 获取熔炼成功的GAMMA数量
    function getForgeWinAmount (address usr) public view returns (uint256 gammaAmount, uint256 usdtAmount) {
        gammaAmount =  forgeWinAmount[usr].gammaAmount;
        usdtAmount = forgeWinAmount[usr].usdtAmount;
    }

    function forgeLow(address referrer) public {
        address sender = msg.sender;

//        requireSystemActive();
        uint256 usdtAmount = USDTAmountLow;
        SystemSetting memory ss = setting;

        // 如果额度不足，则进入下一层
        uint256 gammaAmount = usdtAmount.mul(100).div(ss.price);
        if (ss.curLeftOver < gammaAmount.mul(GROUP_WIN_NUM)) {
            // 如果剩余额度不足一组，则额度累加到下一层
            enterNextLayer();// 返回值为是否进入了奖励赛
            ss = setting;
            gammaAmount = usdtAmount.mul(100).div(ss.price);
        }
        // 最多10轮
        require(ss.round <= TOTAL_ROUND, "total 10 round finisehd");

        TransferHelper.safeTransferFrom(address(gamma), sender, address(this), MIN_GAMMA_REQUIRE);
        TransferHelper.safeTransferFrom(usdt, sender, devaddr, usdtAmount);

        // 记录推荐关系
        refer.submitRefer(sender, referrer);

        // 存储并计算熔炼成功者
        if (winnersLow.length < GROUP_NUM_LIMIT) {
            winnersLow.push(sender);
        }

        if (winnersLow.length == GROUP_NUM_LIMIT) {
            // 计算出3个随机index, 范围[0 - 8]
            (uint256 idx1, uint256 idx2, uint256 idx3) = winnerNumber(GROUP_NUM_LIMIT);

            // 开奖
            for (uint256 i = 0; i < winnersLow.length; i++) {
                address win = winnersLow[i];
                if (i == idx1 || i == idx2 || i == idx3) {
                    // 熔炼成功
                    // 发送GAMMA
                    TransferHelper.safeTransferFrom(gamma, devaddr, win, gammaAmount);
                    forgeWinAmount[win].gammaAmount = forgeWinAmount[win].gammaAmount.add(gammaAmount);
                    forgeWinAmount[win].usdtAmount = forgeWinAmount[win].usdtAmount.add(usdtAmount);

                    // 一级推荐人获得4%
                    address refAddr = refer.getReferrer(win);
                    referBonus[refAddr] = referBonus[refAddr].add(usdtAmount.mul(4).div(100));

                    // 二级推荐人获得1%
                    address refAddr2 = refer.getReferrer(refAddr);
                    referBonus[refAddr2] = referBonus[refAddr2].add(usdtAmount.mul(1).div(100));
                } else {
                    // 熔炼失败
                    // 退还110%
                    uint256 amount = usdtAmount.add(usdtAmount.div(10));
                    TransferHelper.safeTransferFrom(usdt, devaddr, win, amount);

                    // 一级推荐人获得0.8%
                    address refAddr = refer.getReferrer(win);
                    referBonus[refAddr] = referBonus[refAddr].add(usdtAmount.mul(8).div(1000));

                    // 二级推荐人获得0.2%
                    address refAddr2 = refer.getReferrer(refAddr);
                    referBonus[refAddr2] = referBonus[refAddr2].add(usdtAmount.mul(2).div(1000));
                }
            }

            updateLeftOver(gammaAmount);
            updateTotalReferBonus(usdtAmount);

            if (ss.round <= 3) {
                // 取前三轮的20%累积到资金池
                updateRacePoolTotalAmount(usdtAmount.mul(3).div(5));
            } else {
                // 当前轮新增资金量
                updateIncreasedTotalAmount(usdtAmount.mul(3));
            }

            delete winnersLow;
        }
    }

    // 为TOP K分发奖励
    // only dev
    function distributeBonus() public returns (bool) {
        require(msg.sender == devaddr, "dev: only devaddr");

        uint256 totalBonus = getBonus();
        address[] memory topList = getTopRank();
        require(topList.length <= bonusRate.length, "topList above RANK_TOP_NUM");

        for (uint256 i = 0; i < topList.length; i++) {
            uint256 bonus = totalBonus.div(1000).mul(bonusRate[i]);
            TransferHelper.safeTransferFrom(usdt, devaddr, topList[i], bonus);
        }
        return true;
    }

    function claimRewards() public returns (uint256) {
        address sender = msg.sender;
        uint256 rewards = referBonus[sender];
        referBonus[sender] = 0;
        TransferHelper.safeTransferFrom(usdt, devaddr, sender, rewards);
        return rewards;
    }

    function updateLeftOver(uint256 gammaAmount) internal {
        uint256 amount = gammaAmount.mul(3);
        setting.curLeftOver = setting.curLeftOver.sub(amount);
    }

    function updateTotalReferBonus(uint256 usdtAmount) internal {
        uint256 total = totalReferBonus;
        total = total.add(usdtAmount.mul(3).div(20));
        total = total.add(usdtAmount.mul(6).div(100));
        totalReferBonus = total;
    }

    function updateRacePoolTotalAmount(uint256 amount) internal {
        racePoolTotalAmount = racePoolTotalAmount.add(amount);
    }

    function updateIncreasedTotalAmount(uint256 amount) internal {
        increasedTotalAmount = increasedTotalAmount.add(amount);
    }

    function setRacePoolTotalAmount(uint256 amount) public onlyOwner {
        racePoolTotalAmount = amount;
    }

    function setIncreasedTotalAmount(uint256 amount) public onlyOwner {
        increasedTotalAmount = amount;
    }

    // 查询推荐的总收益
    function getReferBonus(address usr) public view returns (uint256) {
        return referBonus[usr];
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

    // 奖励池
    function getBonus() public view returns (uint256) {
        return racePoolTotalAmount.div(7).add(increasedTotalAmount.div(5));
    }

    // 查询在三个熔炼池中成团情况
    function getPendingForge(address usr) public view returns (bool low, bool medium,bool high) {
        low = false;
        medium = false;
        high = false;

        // low
        for (uint256 i = 0; i < winnersLow.length; i++) {
            if (usr == winnersLow[i]) {
                low = true;
                break;
            }
        }
        // medium
        for (uint256 i = 0; i < winnersMedium.length; i++) {
            if (usr == winnersMedium[i]) {
                medium = true;
                break;
            }
        }
        // high
        for (uint256 i = 0; i < winnersHigh.length; i++) {
            if (usr == winnersHigh[i]) {
                high = true;
                break;
            }
        }
    }

    function getTopRank() public view returns (address[] memory) {
        return getTop(RANK_TOP_NUM);
    }

    function getUserRank(address usr) public view returns (uint256) {
        return getRank(usr);
    }

    function updateUserRank(address usr) public returns (bool) {
        uint256 balance = forgeWinAmount[usr].gammaAmount;
        uint256 rankBalance = getRankBalance(usr);
        if (balance > rankBalance) {
            updateRank(usr, balance);
        }
        return true;
    }

    function forgeMedium(address referrer) public {
        address sender = msg.sender;

        //        requireSystemActive();
        uint256 usdtAmount = USDTAmountMedium;
        SystemSetting memory ss = setting;

        // 如果额度不足，则进入下一层
        uint256 gammaAmount = usdtAmount.mul(100).div(ss.price);
        if (ss.curLeftOver < gammaAmount.mul(GROUP_WIN_NUM)) {
            // 如果剩余额度不足一组，则额度累加到下一层
            enterNextLayer();// 返回值为是否进入了奖励赛
            ss = setting;
            gammaAmount = usdtAmount.mul(100).div(ss.price);
        }
        // 最多10轮
        require(ss.round <= TOTAL_ROUND, "total 10 round finisehd");

        TransferHelper.safeTransferFrom(gamma, sender, address(this), MIN_GAMMA_REQUIRE);
        TransferHelper.safeTransferFrom(usdt, sender, devaddr, usdtAmount);

        // 记录推荐关系
        refer.submitRefer(sender, referrer);

        // 存储并计算熔炼成功者
        if (winnersMedium.length < GROUP_NUM_LIMIT) {
            winnersMedium.push(sender);
        }

        if (winnersMedium.length == GROUP_NUM_LIMIT) {
            // 计算出3个随机index, 范围[0 - 8]
            (uint256 idx1, uint256 idx2, uint256 idx3) = winnerNumber(GROUP_NUM_LIMIT);

            // 开奖
            for (uint256 i = 0; i < winnersMedium.length; i++) {
                address win = winnersMedium[i];
                if (i == idx1 || i == idx2 || i == idx3) {
                    // 熔炼成功
                    // 发送GAMMA
                    TransferHelper.safeTransferFrom(gamma, devaddr, win, gammaAmount);
                    forgeWinAmount[win].gammaAmount = forgeWinAmount[win].gammaAmount.add(gammaAmount);
                    forgeWinAmount[win].usdtAmount = forgeWinAmount[win].usdtAmount.add(usdtAmount);

                    // 推荐人获得5%
                    address refAddr = refer.getReferrer(win);
                    referBonus[refAddr] = referBonus[refAddr].add(usdtAmount.div(20));
                } else {
                    // 熔炼失败
                    // 退还110%
                    uint256 amount = usdtAmount.add(usdtAmount.div(10));
                    TransferHelper.safeTransferFrom(usdt, devaddr, win, amount);

                    // 推荐人获得1%
                    address refAddr = refer.getReferrer(win);
                    referBonus[refAddr] = referBonus[refAddr].add(usdtAmount.div(100));
                }
            }

            updateLeftOver(gammaAmount);
            updateTotalReferBonus(usdtAmount);

            if (ss.round <= 3) {
                // 取前三轮的20%累积到资金池
                updateRacePoolTotalAmount(usdtAmount.mul(3).div(5));
            } else {
                // 当前轮新增资金量
                updateIncreasedTotalAmount(usdtAmount.mul(3));
            }

            delete winnersMedium;
        }
    }

    function forgeHigh(address referrer) public {
        address sender = msg.sender;

        //        requireSystemActive();
        uint256 usdtAmount = USDTAmountHigh;
        SystemSetting memory ss = setting;

        // 如果额度不足，则进入下一层
        uint256 gammaAmount = usdtAmount.mul(100).div(ss.price);
        if (ss.curLeftOver < gammaAmount.mul(GROUP_WIN_NUM)) {
            // 如果剩余额度不足一组，则额度累加到下一层
            enterNextLayer();// 返回值为是否进入了奖励赛
            ss = setting;
            gammaAmount = usdtAmount.mul(100).div(ss.price);
        }
        // 最多10轮
        require(ss.round <= TOTAL_ROUND, "total 10 round finisehd");

        TransferHelper.safeTransferFrom(address(gamma), sender, address(this), MIN_GAMMA_REQUIRE);
        TransferHelper.safeTransferFrom(usdt, sender, devaddr, usdtAmount);

        // 记录推荐关系
        refer.submitRefer(sender, referrer);

        // 存储并计算熔炼成功者
        if (winnersHigh.length < GROUP_NUM_LIMIT) {
            winnersHigh.push(sender);
        }

        if (winnersHigh.length == GROUP_NUM_LIMIT) {
            // 计算出3个随机index, 范围[0 - 8]
            (uint256 idx1, uint256 idx2, uint256 idx3) = winnerNumber(GROUP_NUM_LIMIT);

            // 开奖
            for (uint256 i = 0; i < winnersHigh.length; i++) {
                address win = winnersHigh[i];
                if (i == idx1 || i == idx2 || i == idx3) {
                    // 熔炼成功
                    // 发送GAMMA
                    TransferHelper.safeTransferFrom(gamma, devaddr, win, gammaAmount);
                    forgeWinAmount[win].gammaAmount = forgeWinAmount[win].gammaAmount.add(gammaAmount);
                    forgeWinAmount[win].usdtAmount = forgeWinAmount[win].usdtAmount.add(usdtAmount);

                    // 推荐人获得5%
                    address refAddr = refer.getReferrer(win);
                    referBonus[refAddr] = referBonus[refAddr].add(usdtAmount.div(20));
                } else {
                    // 熔炼失败
                    // 退还110%
                    uint256 amount = usdtAmount.add(usdtAmount.div(10));
                    TransferHelper.safeTransferFrom(usdt, devaddr, win, amount);

                    // 推荐人获得1%
                    address refAddr = refer.getReferrer(win);
                    referBonus[refAddr] = referBonus[refAddr].add(usdtAmount.div(100));
                }
            }

            updateLeftOver(gammaAmount);
            updateTotalReferBonus(usdtAmount);

            if (ss.round <= 3) {
                // 取前三轮的20%累积到资金池
                updateRacePoolTotalAmount(usdtAmount.mul(3).div(5));
            } else {
                // 当前轮新增资金量
                updateIncreasedTotalAmount(usdtAmount.mul(3));
            }

            delete winnersHigh;
        }
    }

    // 查询推荐人地址
    function getReferrer(address usr) public view returns (address) {
        return refer.getReferrer(usr);
    }

    // 查询推荐的总人数
    function getReferrerLength(address referrer) public view returns (uint256) {
        return refer.getReferLength(referrer);
    }

    // only dev
    function distributeRewards(address to, uint256 amount) public returns (bool) {
        require(msg.sender == devaddr, "dev: only devaddr");
        TransferHelper.safeTransferFrom(usdt, devaddr, to, amount);
        return true;
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: only devaddr");
        devaddr = _devaddr;
    }

    function withdrawUSDT(uint256 amount) public returns (bool) {
        require(msg.sender == devaddr, "dev: only devaddr");
        TransferHelper.safeTransfer(usdt, devaddr, amount);
        return true;
    }

    function withdrawGAMMA(uint256 amount) public returns (bool) {
        require(msg.sender == devaddr, "dev: only devaddr");
        TransferHelper.safeTransfer(gamma, devaddr, amount);
        return true;
    }
}