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


contract Pausable is Ownable {
    event Paused(address account);
    event Unpaused(address account);

    bool public paused;

    constructor () internal {
        paused = false;
    }

    modifier WhenNotPaused() {
        require(!paused, "Pausable: paused");
        _;
    }

    modifier WhenPaused() {
        require(paused, "Pausable: not paused");
        _;
    }

    function Pause() public onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function Unpause() public onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }
}