pragma solidity 0.5.8;

import "./Ownable.sol";
import "./TRC20.sol";

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

contract GAMMAToken is TRC20("GAMMA Token", "GAMMA"), Ownable {
    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner.
    function mint(address _to) public onlyOwner {
        _mint(_to, MAX_SUPPLY);
    }
}