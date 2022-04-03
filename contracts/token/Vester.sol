pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./IPika.sol";
import "hardhat/console.sol";

contract Vester is Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    struct UserInfo {
        uint256 depositAmount;
        uint256 claimedAmount;
        uint256 vestedUntil;
        uint256 vestingLastUpdate;
    }

    address public esPika;
    address public pika;
    uint256 public vestingPeriod = 365 days;

    uint256 public totalEsPikaDeposit;
    uint256 public totalPikaClaimed;
    mapping(address => uint256) private _balances;

    /// @notice user => depositId => UserInfo
    mapping (address => mapping (uint256 => UserInfo)) public userInfo;
    /// @notice user => depositId[]
    mapping (address => EnumerableSet.UintSet) private allUserDepositIds;
    /// @notice user => deposit index
    mapping (address => uint256) public currentId;

    event Deposit(address indexed user, uint256 depositId, uint256 amount);
    event Withdraw(address indexed user, uint256 depositId, uint256 amount);

    constructor(
        address _esPika,
        address _pika
    ) public {
        esPika = _esPika;
        pika = _pika;
    }

    function deposit(uint256 _amount) external {
        IERC20(esPika).safeTransferFrom(msg.sender, address(this), _amount);
        (UserInfo storage user, uint256 depositId) = _addDeposit(msg.sender);
        totalEsPikaDeposit += _amount;
        user.depositAmount = _amount;
        user.claimedAmount = 0;
        user.vestedUntil = block.timestamp + vestingPeriod;
        user.vestingLastUpdate = block.timestamp;
        emit Deposit(msg.sender, depositId, _amount);
    }

    function withdraw(uint256 _amount, uint256 _depositId) external {
        UserInfo storage user = userInfo[msg.sender][_depositId];
        totalEsPikaDeposit -= _amount;
        claim(_depositId);
        uint256 amountAvailable = user.depositAmount - user.claimedAmount;
        console.log(amountAvailable, _amount);
        if(amountAvailable >= _amount) {
            _amount = amountAvailable;
        }
        user.depositAmount -= _amount;
        IERC20(esPika).safeTransfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _depositId, _amount);
    }

    function claim(uint256 _depositId) public {
        UserInfo storage user = userInfo[msg.sender][_depositId];
        uint256 amountToClaim = claimable(msg.sender, _depositId);
        user.claimedAmount += amountToClaim;
        user.vestingLastUpdate = block.timestamp;
        console.log(amountToClaim, IERC20(esPika).balanceOf(address(this)));
        IPika(esPika).burn(amountToClaim);
        totalPikaClaimed += amountToClaim;
        IERC20(pika).safeTransfer(msg.sender, amountToClaim);
    }

    function claimAll() external {
        uint256[] memory depositIds = allUserDepositIds[msg.sender].values();
        for (uint256 i = 0; i < depositIds.length; i++) {
            claim(depositIds[i]);
        }
    }

    function claimable(address _account, uint256 _depositId) public view returns(uint256) {
        UserInfo memory user = userInfo[_account][_depositId];
        if (user.vestingLastUpdate > user.vestedUntil || user.claimedAmount >= user.depositAmount) {
            return 0;
        }
        if (block.timestamp < user.vestedUntil) {
            return user.depositAmount * (block.timestamp - user.vestingLastUpdate) / vestingPeriod;
        }
        uint256 claimableAmount = user.depositAmount * (user.vestedUntil - user.vestingLastUpdate) / vestingPeriod;
        return claimableAmount + user.claimedAmount > user.depositAmount ? user.depositAmount - user.claimedAmount : claimableAmount;
    }

    function claimableAll(address _account) external view returns(uint256 claimableAmount) {
        uint256 len = allUserDepositIds[_account].length();
        for (uint256 i = 0; i < len; i++) {
            uint256 depositId = allUserDepositIds[_account].at(i);
            claimableAmount += claimable(_account, depositId);
        }
    }

    function claimed(address _account, uint256 _depositId) public view returns(uint256) {
        UserInfo memory user = userInfo[_account][_depositId];
        return user.claimedAmount;
    }

    function claimedAll(address _account) view external returns(uint256 claimedAllAmount) {
        uint256 len = allUserDepositIds[_account].length();
        for (uint256 i = 0; i < len; i++) {
            uint256 depositId = allUserDepositIds[_account].at(i);
            claimedAllAmount += claimed(_account, depositId);
        }
    }

    function vested(address _account, uint256 _depositId) public view returns(uint256) {
        UserInfo memory user = userInfo[_account][_depositId];
        return user.claimedAmount + claimable(_account, _depositId);
    }

    function vestedAll(address _account) view external returns(uint256 vestedAllAmount) {
        uint256 len = allUserDepositIds[_account].length();
        for (uint256 i = 0; i < len; i++) {
            uint256 depositId = allUserDepositIds[_account].at(i);
            vestedAllAmount += vested(_account, depositId);
        }
    }

    function unvested(address _account, uint256 _depositId) public view returns(uint256) {
        UserInfo memory user = userInfo[_account][_depositId];
        return deposited(_account, _depositId) - vested(_account, _depositId);
    }

    function unvestedAll(address _account) view external returns(uint256 unvestedAllAmount) {
        uint256 len = allUserDepositIds[_account].length();
        for (uint256 i = 0; i < len; i++) {
            uint256 depositId = allUserDepositIds[_account].at(i);
            unvestedAllAmount += unvested(_account, depositId);
        }
    }

    function deposited(address _account, uint256 _depositId) public view returns(uint256) {
        return userInfo[_account][_depositId].depositAmount;
    }

    function depositedAll(address _account) external view returns(uint256 depositedAllAmount) {
        uint256 len = allUserDepositIds[_account].length();
        for (uint256 i = 0; i < len; i++) {
            uint256 depositId = allUserDepositIds[_account].at(i);
            depositedAllAmount += deposited(_account, depositId);
        }
    }

    function _addDeposit(address _user) internal virtual returns (UserInfo storage user, uint256 newDepositId) {
        // start depositId from 1
        newDepositId = ++currentId[_user];
        allUserDepositIds[_user].add(newDepositId);
        user = userInfo[_user][newDepositId];
    }

    function setVestingPeriod(uint256 _vestingPeriod) external onlyOwner {
        vestingPeriod = _vestingPeriod;
    }
}
