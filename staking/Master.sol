pragma solidity 0.5.8;

import "./ITRC20.sol";
import "./TRC20.sol";
import "./GDXToken.sol";
import "./Pausable.sol";
import "./Rank.sol";
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


contract Master is Pausable, Rank {
    using SafeMath for uint256;

    /////////////////////////////////////////////////////////
    // for testnet
    bool public flagTestNet = false;
    function setTestFlag(bool flag) public returns (bool) {
        flagTestNet = flag;
        return flagTestNet;
    }
    /////////////////////////////////////////////////////////

    struct ReferRecord {
        address addr;
        uint256 amount;
    }

    // 用户的持币挖矿信息
    struct UserInfo {
        uint256 amount;   // How many GAMMA tokens the user has provided.
        uint256 stakingPower;   // 质押算力
        uint256 referPower;  // 推荐算力
        uint256 minerPoolPower; // 矿主矿池算力
        uint256 extraPower; // 持币算力加成
        uint256 shares;  // shares
        uint256 rewardDebt;  // Reward debt.
        uint256 totalBonus; // 累计收益
        uint256 unStakingAt; // 最近一次取回质押时间，用于计算算力加成
    }

    // 矿池信息
    struct MinePool {
        uint256 id; // 矿池id，对应minePoolInfo数组的索引
        address owner; // 矿池owner，即创建矿池的人
        bytes32 name; // 矿池名称
        uint256 totalAmount; // 抵押的总GAMMA数量
        uint256 totalPower; // 矿池总算力
        uint256 totalAddress; // 总人数
        uint256 totalBonus; // 总收益
        bytes32 hash; // 开通矿池时的区块哈希
    }

    MinePool[] public minePoolInfo; // 保存所有的矿池信息，数组下标即矿池id

    uint256 internal minePoolID = 1; // 矿池的自增索引，每次加1

    // 矿主在矿池中的信息
    struct UserMinePool {
        uint256 id; // 矿池编号
        uint256 amount; // 抵押到矿池的GDX数量
        uint256 power; // 矿主的算力
        uint256 shares; // 矿池挖矿的份额
        uint256 rewardDebt;
        uint256 totalBonus; // 矿主的矿池总收益
    }

    // 用户和所属矿池的映射，及矿主在矿池中的信息
    mapping (address => UserMinePool) public userMinePoolInfo;

    // 抵押挖矿池 和  矿主矿池
    struct PoolInfo {
        uint256 weight;
        uint256 lastRewardBlock;
        uint256 accGDXPerShare;
        uint256 totalShares;
    }
    PoolInfo[] public poolInfo;

    // The GDX， 子币
    GDXToken public gdx;

    // The GAMMA， 母币
    address public gamma;

    // GDX tokens created per block.
    uint256 public gdxPerBlock = 729166; // 3秒一个区块，每天产出21000个

    uint256 public minStakingGAMMA = 100e6; // 最低持币100个GAMMA

    uint256 public totalPower; // 全网总算力

    mapping (address => UserInfo) public userInfo;

    // Reference percentage
    mapping(address => ReferRecord[]) public referRecords;
    Refer public refer;

    mapping (address => uint256) public pendingReferPower; // unsettle refer power

    uint256 constant LEVEL_3 = 3;
    uint256 constant LEVEL_4 = 4;
    uint256 constant LEVEL_5 = 5;

    uint256 constant UPGRADE_REFER_COUNT = 3;

    // 等级
    mapping (address => uint256) public levelMapping;

    // 获取用户的等级
    function levelOf(address owner) public view returns (uint) {
        return levelMapping[owner];
    }

    bool initialized;

    // Events
    event UpgradeLevel(address indexed user, uint256 level);
    event Staking(address indexed user, uint256 amount);
    event Unstaking(address indexed user, uint256 amount);
    event StakingGDX(address indexed user, uint amount);
    event UnstakingGDX(address indexed user, uint256 amount);
    event WithdrawBonus(address indexed user);
    event EmergencyWithdraw(address indexed user, uint256 amount);

    // 构造函数
    constructor (
        GDXToken _gdx,
        address _gamma,
        Refer _refer
    ) public {
        gdx = _gdx;
        gamma = _gamma;
        refer = _refer;
    }

    function init() public onlyOwner {
        if (!initialized) {
            // 抵押和矿池算力部分, 80%
            poolInfo.push(PoolInfo({
                weight:80,
                lastRewardBlock:block.number,
                accGDXPerShare:0,
                totalShares:0
            }));

            // 矿池部分, 20%
            poolInfo.push(PoolInfo({
                weight:20,
                lastRewardBlock:block.number,
                accGDXPerShare:0,
                totalShares:0
            }));

            // 0 矿池
            minePoolInfo.push(MinePool({
                id: 0,
                owner: address(0),
                name:0x64656661756c7400000000000000000000000000000000000000000000000000,
                totalAmount:0,
                totalPower:0,
                totalAddress: 0,
                totalBonus:0,
                hash:blockhash(block.number.sub(1))
            }));

            //            updateMinePoolRank(0, 0);
        }
        initialized = true;
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // 更新所有池子GDX收益
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        uint256 totalSupply = pool.totalShares;
        if (totalSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        require(block.number >= pool.lastRewardBlock, "updatePool failed!");

        uint256 multiplier = block.number.sub(pool.lastRewardBlock);
        uint256 gdxReward = multiplier.mul(gdxPerBlock).mul(pool.weight).div(100);
        gdx.mint(address(this), gdxReward);
        pool.accGDXPerShare = pool.accGDXPerShare.add(gdxReward.mul(1e12).div(totalSupply));
        pool.lastRewardBlock = block.number;
    }

    function updateUserStakingShares(address _usr) internal {
        UserInfo storage user = userInfo[_usr];
        PoolInfo storage pool = poolInfo[0];

        uint256 preUsrShares = user.shares;

        user.shares = user.stakingPower.add(user.extraPower).add(user.referPower).add(user.minerPoolPower);
        user.rewardDebt = user.shares.mul(poolInfo[0].accGDXPerShare).div(1e12);
        require(pool.totalShares.add(user.shares) >= preUsrShares, "updateUserStakingShares failed!");
        pool.totalShares = pool.totalShares.add(user.shares).sub(preUsrShares);
    }

    function updateUserMingPower(address _usr, uint256 _miningPower) internal {
        UserInfo storage user = userInfo[_usr];
        PoolInfo storage pool = poolInfo[0];

        uint256 preUsrShares = user.shares;

        user.minerPoolPower = _miningPower;
        user.shares = user.stakingPower.add(user.extraPower).add(user.referPower).add(user.minerPoolPower);
        user.rewardDebt = user.shares.mul(poolInfo[0].accGDXPerShare).div(1e12);
        require(pool.totalShares.add(user.shares) >= preUsrShares, "updateUserMingPower failed!");
        pool.totalShares = pool.totalShares.add(user.shares).sub(preUsrShares);
    }

    // 获取用户未取回的GDX staking收益
    function pendingGDXUser(address _user) public view returns (uint256) {
        // pool 0
        // staking bonus
        UserInfo storage user = userInfo[_user];
        PoolInfo storage pool = poolInfo[0];
        uint256 stakingBonus;

        uint256 accGDXRate = pool.accGDXPerShare;
        uint256 totalShares = pool.totalShares;
        if (totalShares == 0) {
            stakingBonus = 0;
        } else if (block.number > pool.lastRewardBlock) {
            require(block.number >= pool.lastRewardBlock, "pendingGDXUser failed!");
            uint256 multiplier = block.number.sub(pool.lastRewardBlock);
            uint256 gdxReward = multiplier.mul(gdxPerBlock).div(90); // 区块产出的90%
            accGDXRate = accGDXRate.add(gdxReward.mul(1e12).div(totalShares));

            uint256 reward = user.shares.mul(accGDXRate).div(1e12);
            require(reward >= user.rewardDebt, 'reward < user.rewardDebt');
            stakingBonus =  reward.sub(user.rewardDebt);
        }

        // pool 1
        // mine pool bonus

        uint256 pid;
        bool isPoolOwner;
        (pid, isPoolOwner) = getUserMinePoolID(_user);
        if (pid == 0 || !isPoolOwner) { // 不是矿主
            return stakingBonus;
        }

        pool = poolInfo[1];
        UserMinePool storage mingPoolUser = userMinePoolInfo[_user];
        uint256 miningPoolBonus = 0;

        accGDXRate = pool.accGDXPerShare;
        totalShares = pool.totalShares;
        if (totalShares == 0) {
            miningPoolBonus = 0;
        } else if (block.number > pool.lastRewardBlock) {
            uint256 multiplier = block.number.sub(pool.lastRewardBlock);
            uint256 gdxReward = multiplier.mul(gdxPerBlock).div(10); // 区块产出的10%
            accGDXRate = accGDXRate.add(gdxReward.mul(1e12).div(totalShares));

            uint256 reward = mingPoolUser.shares.mul(accGDXRate).div(1e12);
            require(reward >= mingPoolUser.rewardDebt, 'reward < user.rewardDebt');
            miningPoolBonus =  reward.sub(mingPoolUser.rewardDebt);
        }

        return stakingBonus.add(miningPoolBonus);
    }

    // 增加全网算力
    function addTotalPower(uint256 value) internal {
        totalPower = totalPower.add(value);
    }

    // 减少全网算力
    function subTotalPower(uint256 value) internal {
        if (totalPower < value) {
            require(false, "total power < value");
        }

        totalPower = totalPower.sub(value);
    }

    // 计算直推算力，即amount的20%
    function getReferPower(uint256 _amount, uint256 idx) internal pure returns (uint256) {
        if (1 == idx) {
            return _amount.mul(20).div(100);
        } else {
            return _amount.mul(4).div(100);
        }
    }

    // 结算用户staking收益
    function payStakingBonus(address usr) internal {
        UserInfo storage user = userInfo[usr];

        uint256 pid;
        (pid,) = getUserMinePoolID(usr);

        // 结算收益
        if (user.shares > 0) {
            uint256 reward = user.shares.mul(poolInfo[0].accGDXPerShare).div(1e12);
            if (reward < user.rewardDebt) {
                require(false, "reward < user.rewardDebt");
            }
            uint256 pending = reward.sub(user.rewardDebt);
            if (pending > 0) {
                safeGDXTransfer(usr, pending);
                // 更新用户总收益
                user.totalBonus = user.totalBonus.add(pending);
                if (pid != 0) {
                    MinePool storage pool = minePoolInfo[pid];
                    // 更新矿池的总收益
                    pool.totalBonus = pool.totalBonus.add(pending);
                }
            }
        }
    }

    function checkRefer(address upline, uint256 idx) internal view returns (bool) {
        //        // 矿主无限代
        //        bool isPoolOwner;
        //        (, isPoolOwner) = getUserMinePoolID(upline);
        //        if (isPoolOwner) {
        //            return true;
        //        }

        // 根据V等级，判断拿多少代
        uint256 level = getLevel(upline);
        if (0 == level) { // V0 拿1代
            return idx <= 1;
        } else if (1 == level) { // V1 拿3代
            return idx <= 3;
        } else if (2 == level) { // V2拿6代
            return idx <= 6;
        } else { // V3 以上拿9代
            return idx <= 9;
        }
    }

    function updateReferPower(address account) public {
        UserInfo storage user = userInfo[account];
        payStakingBonus(account);

        user.extraPower = getExtraPower(account);
        updateUserStakingShares(account);
    }

    // 存入GAMMA， 开启持币算力挖矿
    function staking(uint256 _amount, address referrer) public {
        require(_amount > 0, "staking amount must > 0");

        address sender = msg.sender;
        UserInfo storage user = userInfo[sender];

        massUpdatePools();

        // 结算在此之前的收益
        payStakingBonus(sender);

        // 转移GAMMA
        require(ITRC20(gamma).transferFrom(sender, address(this), _amount), "deposit transfer failed");

        // 更新用户质押份额
        user.amount = user.amount.add(_amount);
        user.stakingPower = user.stakingPower.add(_amount);
        // 更新持币周期加成
        if (user.unStakingAt == 0) {
            user.unStakingAt = block.timestamp;
        }
        user.extraPower = getExtraPower(sender);
        updateUserStakingShares(sender);

        // 更新总算力
        addTotalPower(_amount);

        // 记录推荐关系
        refer.submitRefer(msg.sender, referrer);

        // 更新推荐人算力
        // 最多向上更新9代
        address referee = sender;
        address upline = refer.getReferrer(referee);
        for (uint256 i = 1; i <= 9; i++) {
            if (address(0) == upline) {
                break;
            }

            bool flag = checkRefer(upline, i);
            if (flag) {
                UserInfo storage ref = userInfo[upline];

                // 结算推荐人收益
                payStakingBonus(upline);

                uint256 extraPower = getReferPower(_amount, i); // 推荐人获得直推算力20%加成
                ref.referPower = ref.referPower.add(extraPower);
                updateUserStakingShares(upline);

                // 更新总算力
                addTotalPower(extraPower);

                if (i == 1) {
                    // 推荐记录
                    // 只记录直推记录
                    referRecords[upline].push(ReferRecord({
                        addr:sender,
                        amount:_amount
                    }));
                }
            }

            referee = upline;
            upline = refer.getReferrer(referee);
        }

        emit Staking(sender, _amount);

        // 更新矿池
        uint256 pid;
        bool isOwner;
        (pid, isOwner) = getUserMinePoolID(sender);
        if (pid != 0) { // 矿池存在
            MinePool storage minePool = minePoolInfo[pid];
            if (!isOwner) { // 不是矿主
                uint256 extraPower = getMinePoolAddition(getLevel(sender)).mul(_amount).div(1000);
                minePool.totalPower = minePool.totalPower.add(extraPower);
            } else { // 矿主
                minePool.totalPower = minePool.totalPower.add(_amount);
            }
            updateUserMingPower(minePool.owner, minePool.totalPower);
        }
    }

    // 取回GAMMA和GDX收益，结束持币算力挖矿
    function unstaking(uint256 _amount) public {
        require(_amount > 0, "unstaking amount must > 0");

        address sender = msg.sender;
        UserInfo storage user = userInfo[sender];
        if (user.amount < _amount) {
            require(false, "user amount xxxxxx");
        }

        if (user.stakingPower < _amount) {
            require(false, "user staking power error!");
        }

        // 更新staking池
        updatePool(0);

        // 结算在此之前的收益
        payStakingBonus(sender);

        if (ITRC20(gamma).balanceOf(address(this)) < _amount) {
            require(false, "master contract gamma insufficient!!");
        }

        // 返还质押的GAMMA
        require(ITRC20(gamma).transfer(address(sender), _amount), "withdraw transfer failed");

        // 更新用户质押份额
        user.amount = user.amount.sub(_amount);
        user.stakingPower = user.stakingPower.sub(_amount);
        // 更新用户质押权重
        user.extraPower = getExtraPower(sender);
        user.unStakingAt = block.timestamp;
        updateUserStakingShares(sender);

        // 减少全网算力
        subTotalPower(_amount);

        // 更新推荐算力
        address referr = refer.getReferrer(sender);
        UserInfo storage ref = userInfo[referr];
        if (address(0) != referr) {
            payStakingBonus(referr);

            uint256 referPower = getReferPower(_amount, 1); // 推荐人获得直推算力20%加成

            if (ref.referPower < referPower) {
                require(false, "ref.referPower < referPower");
            }
            if (ref.shares < referPower) {
                require(false, "ref.shares < referPower");
            }
            ref.referPower = ref.referPower.sub(referPower);
            updateUserStakingShares(referr);

            // 减少全网算力
            subTotalPower(referPower);
        }

        // 更新矿池
        uint256 pid;
        bool isOwner;
        (pid, isOwner) = getUserMinePoolID(sender);
        if (pid != 0) { // 矿池存在
            MinePool storage minePool = minePoolInfo[pid];
            if (!isOwner) { // 不是矿主
                uint256 extraPower = getMinePoolAddition(getLevel(sender)).mul(_amount).div(1000);
                require(minePool.totalPower >= extraPower, "unstaking: totalPower < extraPower");
                minePool.totalPower = minePool.totalPower.sub(extraPower);
            } else { // 矿主
                require(minePool.totalPower >= _amount, "unstaking: totalPower < _amount");
                minePool.totalPower = minePool.totalPower.sub(_amount);
            }
            updateUserMingPower(minePool.owner, minePool.totalPower);
        }

        emit Unstaking(msg.sender, _amount);
    }

    // 取回所有挖矿收益GDX，包括质押和矿池收益
    function withdrawBonus() public {
        address sender = msg.sender;

        UserInfo storage user = userInfo[sender];

        // 更新全局收益GDX
        massUpdatePools();

        // 取回收益GDX
        payStakingBonus(sender);
        user.rewardDebt = user.shares.mul(poolInfo[0].accGDXPerShare).div(1e12);
        if (user.unStakingAt == 0) {
            user.unStakingAt = block.timestamp;
        }
        updateUserStakingShares(sender);

        // 取回矿池收益
        uint256 pid;
        bool isOwner;
        (pid, isOwner) = getUserMinePoolID(sender);
        if (isOwner) {
            payMinePoolOwnerBonus(pid, sender);
            UserMinePool storage pool = userMinePoolInfo[sender];
            pool.rewardDebt = pool.shares.mul(poolInfo[1].accGDXPerShare).div(1e12);
            updateUserMingPower(sender,minePoolInfo[pid].totalPower);
        }

        emit WithdrawBonus(msg.sender);

    }

    // 创建矿池, 并质押一定数量的GAMMA
    function createPool(bytes32 name, uint256 amount) public returns (bool) {
        address sender = msg.sender;

        uint256 level = levelMapping[sender];
        require(level >= LEVEL_3, "level error");

        if (level == LEVEL_3) {
            require(amount >= 3000e6, "V3 need 3000 GDX");
        }
        if (level == LEVEL_4) {
            require(amount >= 5000e6, "V4 need 5000 GDX");
        }
        if (level == LEVEL_5) {
            require(amount >= 6000e6, "V5 need 6000 GDX");
        }

        bool isPoolOwner;
        (, isPoolOwner) = getUserMinePoolID(sender);
        require(!isPoolOwner, "pool already exist");

        // 转移GDX
        require(gdx.transferFrom(sender, address(this), amount), "createPool: transfer failed");

        // 统计矿池算力
        address[] memory list = getReferList(sender);
        uint256 poolAmount = getUsrMiningPower(sender);
        for (uint256 i = 0; i < list.length; i++) {
            address addr = list[i];
            uint256 amnt = userInfo[addr].amount;
            poolAmount = poolAmount.add(amnt);
        }

        uint256 poolID = getNewPoolID();
        // 创建矿池
        minePoolInfo.push(MinePool({
            id: poolID,
            owner: sender,
            name:name,
            totalAmount: poolAmount,
            totalPower: poolAmount,
            totalAddress: list.length.add(1),
            totalBonus:0,
            hash:blockhash(block.number.sub(1))
        }));

        // 添加矿池排名
        updateMinePoolRank(poolID, amount);

        // 保存 <用户 -> 矿池> 信息
        uint256 miningPower = getMinePoolAddition(getLevel(sender)).mul(poolAmount).div(1000);
        userMinePoolInfo[sender] = UserMinePool({
            id: poolID,
            amount:amount,
            power:miningPower,
            shares:amount,
            rewardDebt: 0,
            totalBonus:0
        });

        // 结算质押收益
        massUpdatePools();
        payStakingBonus(sender);

        // 更新周期加成
        UserInfo storage user = userInfo[sender];
        user.extraPower = getExtraPower(sender);
        updateUserStakingShares(sender);

        return true;
    }

    // 更新矿池排名
    function updateMinePoolRank(uint256 poolID, uint256 power) internal {
        updateRank(poolID, power);
    }

    // 获取下一个矿池的id
    function getNewPoolID() internal returns (uint256 id) {
        id = minePoolID;
        minePoolID = minePoolID.add(1);
    }

    function payMinePoolOwnerBonus(uint256 pid, address owner) internal {
        MinePool storage pool = minePoolInfo[pid];
        UserMinePool storage user = userMinePoolInfo[owner];

        require(pool.owner == owner, "can only pay bonus to pool owner");

        // 结算收益
        if (user.shares > 0) {
            uint256 reward = user.shares.mul(poolInfo[1].accGDXPerShare).div(1e12);
            if (reward < user.rewardDebt) {
                require(false, "payMinePoolOwnerBonus: reward < user.rewardDebt");
            }
            uint256 pending = reward.sub(user.rewardDebt);
            if (pending > 0) {
                safeGDXTransfer(owner, pending);
                // 统计信息
                // 更新矿主的矿池总收益
                user.totalBonus = user.totalBonus.add(pending);
                // 更新矿池的总收益
                pool.totalBonus = pool.totalBonus.add(pending);
            }
        }
    }

    // 增加矿池质押, 并质押一定数量的GDX
    // 需要先开通矿池，否则无法质押GDX
    function stakingGDX(uint256 amount) public returns (bool) {
        address sender = msg.sender;

        uint256 pid;
        bool isPoolOwner;
        (pid, isPoolOwner) = getUserMinePoolID(sender);

        if (!isPoolOwner) {
            return false;
        }

        MinePool storage pool = minePoolInfo[pid];
        // 检查是否为矿主
        require(pool.owner == sender, "only pool owner can operate");

        // 转移GDX
        require(gdx.transferFrom(sender, address(this), amount), "stakingGDX: transfer failed");

        // 分配矿池收益
        updatePool(1);

        // 结算矿主收益
        payMinePoolOwnerBonus(pid, sender);

        // 更新用户信息
        UserMinePool storage user = userMinePoolInfo[sender];
        user.id = pid;
        user.amount = user.amount.add(amount);
        user.shares = calcUsrMingPoolShares(sender, user.amount);
        user.rewardDebt = user.shares.mul(poolInfo[1].accGDXPerShare).div(1e12);

        // 更新矿池排名
        updateMinePoolRank(pid, user.amount);

        emit StakingGDX(sender, amount);

        return true;
    }

    function calcUsrMingPoolShares(address _usr, uint256 _amount) internal view returns (uint256) {
        uint256 levl = getLevel(_usr);
        if (3 == levl) {
            return _amount.mul(5);
        } else if (4 == levl) {
            return _amount.mul(3);
        } else if (5 == levl) {
            return _amount.mul(2);
        }
        return _amount;
    }

    // 解除矿池质押的GDX
    function unstakingGDX(uint256 amount) public returns (bool) {
        address sender = msg.sender;

        uint256 pid;
        bool isPoolOwner;
        (pid, isPoolOwner) = getUserMinePoolID(sender);

        require(pid != 0 && isPoolOwner, "no pool or not pool owner");

        MinePool storage pool = minePoolInfo[pid];
        UserMinePool storage user =  userMinePoolInfo[sender];

        // 检查是否为矿主
        require(pool.owner == sender, "only pool owner can operate");
        require(user.amount >= amount, "unstaking amount too large than user");

        // 分配矿池收益
        updatePool(1);

        // 结算矿主收益
        payMinePoolOwnerBonus(pool.id, sender);

        require(gdx.transfer(msg.sender, amount), "unstakingGDX: transfer failed");

        // 更新用户信息
        user.amount = user.amount.sub(amount);
        user.shares = calcUsrMingPoolShares(sender, user.amount);
        user.rewardDebt = user.shares.mul(poolInfo[1].accGDXPerShare).div(1e12);

        // 更新矿池排名
        updateMinePoolRank(pid, user.amount);

        emit UnstakingGDX(sender, amount);

        return true;
    }

    //  矿池总数量
    function getTotalPoolNum() public view returns (uint256) {
        return (minePoolInfo.length).sub(1);
    }

    // 获取用户等级
    function getLevel(address owner) public view returns (uint256) {
        return levelMapping[owner];
    }

    // 获取获取推荐
    function getReferList(address usr) public view returns (address[] memory) {
        uint256 referLen = refer.getReferLength(usr);
        address[] memory addrList = new address[](referLen);
        for(uint256 i = 0; i < referLen; i++) {
            addrList[i] = refer.referList(usr, i);
        }
        return addrList;
    }

    // 是否可升级等级？
    function canUpgradeLevel(address owner, uint256 levl) public view returns (bool) {
        ///////////////////////////////////////////
        if (flagTestNet) {
            return true;
        }
        ///////////////////////////////////////////

        address sender = msg.sender;

        if (levelMapping[owner] >= levl || levl >= LEVEL_5) {
            return false;
        }

        // 获取推荐列表
        address[] memory list = getReferList(sender);
        uint256 cnt = 0;
        for(uint256 i = 0; i < list.length; i++) {
            address addr = list[i];
            uint256 balance = ITRC20(gamma).balanceOf(addr);
            uint256 stakingPower = getUsrMiningPower(addr);
            if (getLevel(addr) >= levl - 1 && (balance >= minStakingGAMMA || stakingPower >= minStakingGAMMA)) {
                cnt++;
            }
        }
        if (cnt < UPGRADE_REFER_COUNT) {
            return false;
        }

        return true;
    }

    // 升级V
    function upgradeLevel(address owner, uint256 levl) public {
        address sender = msg.sender;
        uint origin = levelMapping[owner];

        ///////////////////////////////////////////
        if (flagTestNet) {
            levelMapping[sender] = levl;
            return;
        }
        ///////////////////////////////////////////

        require(origin < levl && levl < LEVEL_5, "cannot upgrade level");

        // 获取推荐列表
        address[] memory list = getReferList(sender);
        uint256 cnt = 0;
        for(uint256 i = 0; i < list.length; i++) {
            address addr = list[i];
            uint256 balance = ITRC20(gamma).balanceOf(addr);
            uint256 stakingPower = getUsrMiningPower(addr);
            if (getLevel(addr) >= levl - 1 && (balance >= minStakingGAMMA || stakingPower >= minStakingGAMMA)) {
                cnt++;
            }
        }
        require(cnt >= UPGRADE_REFER_COUNT, "upgrade failed, insufficient referrer count");

        levelMapping[sender] = levl;
        emit UpgradeLevel(sender, levl);
    }

    // 获取矿池算力加成因子
    // 返回结果放大了1000倍
    function getMinePoolAddition(uint256 level) internal pure returns (uint256) {
        uint256 multiplier = 0;
        if (level == 3) {
            multiplier = 50;
        } else if (level == 4) {
            multiplier = 80;
        } else if (level == 5) {
            multiplier = 100;
        }
        return 0;
    }

    // 查询top K矿池列表，返回的是矿池id列表
    function getTopKPools(uint256 k) public view returns (uint256[] memory) {
        return getTop(k);
    }

    // 查询全网算力
    function getTotalPower() public view returns (uint256) {
        return totalPower;
    }

    // 获取用户所属的矿池id
    function getUserMinePoolID(address user) public view returns (uint256, bool) {
        // 1. 若用户为矿主，则返回其矿池id 和 true (表示为矿主)
        // 2. 若第1步中，id为0，表示用户尚未开通矿池，则返回其推荐人的的矿池id 和 false (表示非矿主)
        bool isPoolOwner = false;
        uint256 id = userMinePoolInfo[user].id;
        if (0 != id) {
            isPoolOwner = true;
        } else {
            address referrer = refer.getReferrer(user);
            id = userMinePoolInfo[referrer].id;
        }
        return (id, isPoolOwner);
    }

    // 获取用户所属的矿池总人数
    function getUserMinePoolTotalAddress(address usr) public view returns (uint256) {
        uint256 id = userMinePoolInfo[usr].id;
        return minePoolInfo[id].totalAddress;
    }

    // 矿池中质押的GDX数量
    function getUserMingPoolGDXAmount(address usr) public view returns (uint256) {
        return userMinePoolInfo[usr].amount;
    }

    // 我的推荐权重
    function getReferPower(address usr) public view returns (uint256) {
        return userInfo[usr].referPower;
    }

    // 我的矿池权重
    function getUsrPoolPower(address usr) public view returns (uint256) {
        uint256 pid;
        bool isPoolOwner;
        (pid, isPoolOwner) = getUserMinePoolID(usr);
        if (!isPoolOwner) { // 非矿主，返回0
            return 0;
        }
        return minePoolInfo[pid].totalPower;
    }

    // 我的质押挖矿权重
    function getUsrMiningPower(address usr) public view returns (uint256) {
        UserInfo storage info = userInfo[usr];
        return info.stakingPower;
    }

    // 我的矿池收益
    function getUsrMiningBonus(address usr) public view returns (uint256) {
        uint256 id = userMinePoolInfo[usr].id;
        return minePoolInfo[id].totalBonus;
    }

    // 我的累计收益
    function getUsrTotalBonus(address usr) public view returns (uint256) {
        UserInfo storage info = userInfo[usr];
        return info.totalBonus;
    }

    // 我的当前运行周期
    function getUsrPeriod(address usr) public view returns (uint256) {
        uint256 base = 1 days;
        if (flagTestNet) {
            base = 1 hours;
        }

        UserInfo storage info = userInfo[usr];
        if (0 == info.unStakingAt) {
            return 0;
        }
        return (block.timestamp.sub(info.unStakingAt)).div(base);
    }

    // 我的权重占比
    function getUsrWeightPercent(address usr) public view returns (uint256) {
        if (totalPower <= 0) {
            return 0;
        }

        uint256 shares = userInfo[usr].shares;
        return shares.mul(1e8).div(totalPower);
    }

    // 我的周期加成
    function getExtraPower(address usr) public view returns (uint256) {
        uint256 base = 10 days;
        if (flagTestNet) {
            base = 1 hours;
        }

        UserInfo storage info = userInfo[usr];
        require(block.timestamp >= info.unStakingAt, "getExtraPower failed!");
        uint256 delta = (block.timestamp.sub(info.unStakingAt)).div(base);
        if (delta > 3) {
            delta = 3;
        }

        // 小于最小质押数量，不统计权重
        if (info.stakingPower < minStakingGAMMA) {
            return 0;
        }
        return info.stakingPower.mul(5).mul(delta).div(100);
    }

    // 我的推荐记录数量
    function referRecordsLength(address usr) public view returns (uint256) {
        return referRecords[usr].length;
    }

    // 我的有效邀请算力
    function getRealReferPower(address usr) public view returns (uint256) {
        UserInfo storage info = userInfo[usr];

        // 小于最小质押数量，不统计权重
        if (info.stakingPower < minStakingGAMMA) {
            return 0;
        }
        return info.referPower;
    }

    // 我的总邀请算力
    function getTotalReferPower(address usr) public view returns (uint256) {
        uint256 len = referRecordsLength(usr);
        uint totalReferPower = 0;
        for (uint256 i = 0; i < len; i++) {
            totalReferPower = totalReferPower.add(referRecords[usr][i].amount);
        }
        return totalReferPower;
    }

    // Safe GDX transfer function, just in case if rounding error causes pool to not have enough GDXs.
    function safeGDXTransfer(address _to, uint256 _amount) internal {
        uint256 gdxBal = gdx.balanceOf(address(this));
        if (_amount > gdxBal) {
            gdx.transfer(_to, gdxBal);
        } else {
            gdx.transfer(_to, _amount);
        }
    }

    // Update GDX Token ownership, for upgrade
    function transferGDXTokenOwnership(address newOwner) public onlyOwner {
        gdx.transferOwnership(newOwner);
    }

    function withdrawGAMMA(uint256 amount) public onlyOwner returns (bool) {
        ITRC20(gamma).transfer(msg.sender, amount);
        return true;
    }

    function withdrawGDX(uint256 amount) public onlyOwner returns (bool) {
        safeGDXTransfer(msg.sender, amount);
        return true;
    }
}