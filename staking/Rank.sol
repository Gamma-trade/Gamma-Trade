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
    mapping(uint256 => uint256)  values; // 矿池id -> 矿池算力
    mapping(uint256 => uint256)  _nextId; // 矿池id的前后关系
    uint256 public listSize;
    uint256 constant GUARD = 0;

    constructor() public {
        _nextId[GUARD] = GUARD;
    }

    function addRankId(uint256 id, uint256 value) internal {
        if (_nextId[id] != 0) {
            return;
        }

        uint256 index = _findIndex(value);
        values[id] = value;
        _nextId[id] = _nextId[index];
        _nextId[index] = id;
        listSize++;
    }

    function removeRankId(uint256 id) internal {
        if (_nextId[id] == 0) {
            return;
        }

        uint256 prevId = _findPrevId(id);
        _nextId[prevId] = _nextId[id];

        _nextId[id] = 0;
        values[id] = 0;
        listSize--;
    }

    function isContains(uint256 id) internal view returns (bool) {
        return _nextId[id] != 0;
    }

    function getRank(uint256 id) public view returns (uint256) {
        if (!isContains(id)) {
            return 0;
        }

        uint idx = 0;
        uint256 currentId = GUARD;
        while(_nextId[currentId] != GUARD) {
            if (id != currentId) {
                currentId = _nextId[currentId];
                idx++;
            } else {
                break;
            }
        }
        return idx;
    }

    function getRankValue(uint256 id) internal view returns (uint256) {
        return values[id];
    }

    function getTop(uint256 k) public view returns (uint256[] memory) {
        if (k > listSize) {
            k = listSize;
        }

        uint256[] memory idLists = new uint256[](k);
        uint256 currentId = _nextId[GUARD];
        for (uint256 i = 0; i < k; ++i) {
            idLists[i] = currentId;
            currentId = _nextId[currentId];
        }

        return idLists;
    }

    function updateRank(uint256 id, uint256 newValue) internal {
        if (!isContains(id)) {
            // 如果不存在，则添加
            addRankId(id, newValue);
        } else {
            // 已存在，则更新
            uint256 prevId = _findPrevId(id);
            uint256 nextId = _nextId[id];
            if (_verifyIndex(prevId, newValue, nextId)) {
                values[id] = newValue;
            } else {
                removeRankId(id);
                addRankId(id, newValue);
            }
        }
    }

    function _isPrevId(uint256 id, uint256 prevId) internal view returns (bool) {
        return _nextId[prevId] == id;
    }

    // 用于验证该值在左右地址之间
    // 如果 左边的值 ≥ 新值 > 右边的值将返回 true(如果我们保持降序，并且如果值等于，则新值应该在旧值的后面)
    function _verifyIndex(uint256 prevId, uint256 newValue, uint256 nextId)
    internal
    view
    returns (bool) {
        return (prevId == GUARD || values[prevId] >= newValue) &&
        (nextId == GUARD || newValue > values[nextId]);
    }

    // 用于查找新值应该插入在哪一个地址后面
    function _findIndex(uint256 newValue) internal view returns (uint256) {
        uint256 candidateId = GUARD;
        while(true) {
            if (_verifyIndex(candidateId, newValue, _nextId[candidateId]))
                return candidateId;

            candidateId = _nextId[candidateId];
        }
    }

    function _findPrevId(uint256 id) internal view returns (uint256) {
        uint256 currentId = GUARD;
        while(_nextId[currentId] != GUARD) {
            if (_isPrevId(id, currentId))
                return currentId;

            currentId = _nextId[currentId];
        }
        return 0;
    }
}