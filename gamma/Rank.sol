pragma solidity 0.5.8;

import "./Ownable.sol";

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

contract Rank is Ownable {
    mapping(address => uint256)  balances;
    mapping(address => address)  _nextAddress;
    uint256 public listSize;
    address constant GUARD = address(1);

    constructor() public {
        _nextAddress[GUARD] = GUARD;
    }

    function addRankAddress(address addr, uint256 balance) internal {
        if (_nextAddress[addr] != address(0)) {
            return;
        }

        address index = _findIndex(balance);
        balances[addr] = balance;
        _nextAddress[addr] = _nextAddress[index];
        _nextAddress[index] = addr;
        listSize++;
    }

    function removeRankAddress(address addr) internal {
        if (_nextAddress[addr] == address(0)) {
            return;
        }

        address prevAddress = _findPrevAddress(addr);
        _nextAddress[prevAddress] = _nextAddress[addr];

        _nextAddress[addr] = address(0);
        balances[addr] = 0;
        listSize--;
    }

    function isContains(address addr) internal view returns (bool) {
        return _nextAddress[addr] != address(0);
    }

    function getRank(address addr) public view returns (uint256) {
        if (!isContains(addr)) {
            return 0;
        }

        uint idx = 0;
        address currentAddress = GUARD;
        while(_nextAddress[currentAddress] != GUARD) {
            if (addr != currentAddress) {
                currentAddress = _nextAddress[currentAddress];
                idx++;
            } else {
                break;
            }
        }
        return idx;
    }

    function getRankBalance(address addr) internal view returns (uint256) {
        return balances[addr];
    }

    function getTop(uint256 k) public view returns (address[] memory) {
        if (k > listSize) {
            k = listSize;
        }

        address[] memory addressLists = new address[](k);
        address currentAddress = _nextAddress[GUARD];
        for (uint256 i = 0; i < k; ++i) {
            addressLists[i] = currentAddress;
            currentAddress = _nextAddress[currentAddress];
        }

        return addressLists;
    }

    function updateRank(address addr, uint256 newBalance) internal {
        if (!isContains(addr)) {
            // 如果不存在，则添加
            addRankAddress(addr, newBalance);
        } else {
            // 已存在，则更新
            address prevAddress = _findPrevAddress(addr);
            address nextAddress = _nextAddress[addr];
            if (_verifyIndex(prevAddress, newBalance, nextAddress)) {
                balances[addr] = newBalance;
            } else {
                removeRankAddress(addr);
                addRankAddress(addr, newBalance);
            }
        }
    }

    function _isPrevAddress(address addr, address prevAddress) internal view returns (bool) {
        return _nextAddress[prevAddress] == addr;
    }

    // 用于验证该值在左右地址之间
    // 如果 左边的值 ≥ 新值 > 右边的值将返回 true(如果我们保持降序，并且如果值等于，则新值应该在旧值的后面)
    function _verifyIndex(address prevAddress, uint256 newValue, address nextAddress)
    internal
    view
    returns (bool) {
        return (prevAddress == GUARD || balances[prevAddress] >= newValue) &&
        (nextAddress == GUARD || newValue > balances[nextAddress]);
    }

    // 用于查找新值应该插入在哪一个地址后面
    function _findIndex(uint256 newValue) internal view returns (address) {
        address candidateAddress = GUARD;
        while(true) {
            if (_verifyIndex(candidateAddress, newValue, _nextAddress[candidateAddress]))
                return candidateAddress;

            candidateAddress = _nextAddress[candidateAddress];
        }
    }

    function _findPrevAddress(address addr) internal view returns (address) {
        address currentAddress = GUARD;
        while(_nextAddress[currentAddress] != GUARD) {
            if (_isPrevAddress(addr, currentAddress))
                return currentAddress;

            currentAddress = _nextAddress[currentAddress];
        }
        return address(0);
    }
}