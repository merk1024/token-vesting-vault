// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VestingVault — token vesting with cliff, linear unlock and revocation (STUDENT STARTER)
/// @notice One vault holds tokens for many beneficiaries. The owner (e.g. the project team)
///         creates schedules; beneficiaries (team, investors, advisors) receive tokens over time.
contract VestingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    //  PROVIDED PART (identical to the student starter file)
    // ============================================================
    struct Schedule {
        address beneficiary;
        uint256 total;      // total tokens promised
        uint256 released;   // tokens already paid out
        uint64 start;       // unix time when vesting starts
        uint64 cliff;       // seconds after `start` before ANY token vests
        uint64 duration;    // seconds after `start` when 100% is vested
        uint64 revokedAt;   // 0 while not revoked
        bool revocable;
        bool revoked;
    }

    IERC20 public immutable token;
    uint256 public scheduleCount;                       // ids start from 1
    uint256 public totalAllocated;                      // tokens promised to beneficiaries and not yet paid out
    mapping(uint256 => Schedule) public schedules;
    mapping(address => uint256[]) private _schedulesOf;

    event ScheduleCreated(uint256 indexed id, address indexed beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration, bool revocable);
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event Revoked(uint256 indexed id, uint256 returnedToOwner);
    event ScheduleTransferred(uint256 indexed id, address indexed from, address indexed to);

    constructor(IERC20 token_) Ownable(msg.sender) {
        require(address(token_) != address(0), "zero token");
        token = token_;
    }

    // ============================================================
    //  YOUR CODE STARTS HERE
    // ============================================================

    // ------------------------------------------------------------
    // STEP 1 — create a schedule (owner only)
    // Validate: beneficiary != 0, amount > 0, duration > 0, cliff <= duration,
    //   and the vault must hold enough NOT-YET-PROMISED tokens:
    //   token.balanceOf(address(this)) - totalAllocated >= amount
    // Then: id = ++scheduleCount, store the Schedule (released = 0, revokedAt = 0, revoked = false),
    //   remember the id in _schedulesOf[beneficiary], totalAllocated += amount,
    //   emit ScheduleCreated. Return the id.
    // ------------------------------------------------------------
    function createSchedule(
        address beneficiary,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    ) external onlyOwner returns (uint256 id) {
        require(beneficiary != address(0), "zero beneficiary");
        require(amount > 0, "zero amount");
        require(duration > 0, "zero duration");
        require(cliff <= duration, "cliff exceeds duration");
        uint256 balance = token.balanceOf(address(this));
        require(balance >= totalAllocated && balance - totalAllocated >= amount, "insufficient unallocated tokens");

        id = ++scheduleCount;
        schedules[id] = Schedule({
            beneficiary: beneficiary, total: amount, released: 0,
            start: start, cliff: cliff, duration: duration, revokedAt: 0,
            revocable: revocable, revoked: false
        });
        _schedulesOf[beneficiary].push(id);
        totalAllocated += amount;
        emit ScheduleCreated(id, beneficiary, amount, start, cliff, duration, revocable);
    }

    // ------------------------------------------------------------
    // STEP 2 — the vesting formula
    // Let t = block.timestamp, but if the schedule was revoked use s.revokedAt instead.
    //   t <  start + cliff       -> 0
    //   t >= start + duration    -> total
    //   otherwise                -> total * (t - start) / duration     (integer division, rounds down)
    // vestedAmount(id) reverts for an unknown id. releasable(id) = vestedAmount(id) - released.
    // ------------------------------------------------------------
    function vestedAmount(uint256 id) public view returns (uint256) {
        require(id > 0 && id <= scheduleCount, "unknown schedule");
        return _vested(schedules[id]);
    }

    function releasable(uint256 id) public view returns (uint256) {
        require(id > 0 && id <= scheduleCount, "unknown schedule");
        return _vested(schedules[id]) - schedules[id].released;
    }

    // ------------------------------------------------------------
    // STEP 3 — release (ANYONE may call it, tokens always go to the beneficiary)
    // Reverts if the id is unknown or there is nothing to release.
    // Order matters: update state FIRST (released, totalAllocated), send tokens LAST.
    // Use SafeERC20 (token.safeTransfer). Emit Released.
    // ------------------------------------------------------------
    function release(uint256 id) external nonReentrant {
        require(id > 0 && id <= scheduleCount, "unknown schedule");
        Schedule storage s = schedules[id];
        uint256 amount = _vested(s) - s.released;
        require(amount > 0, "nothing to release");
        s.released += amount;
        totalAllocated -= amount;
        token.safeTransfer(s.beneficiary, amount);
        emit Released(id, s.beneficiary, amount);
    }

    // ------------------------------------------------------------
    // STEP 4 — revoke (owner only)
    // Only for revocable, not yet revoked schedules.
    // The UNVESTED part (total - vested now) goes back to the owner immediately.
    // The already vested part stays claimable by the beneficiary via release().
    // After revoking, vesting is frozen: set revoked = true, revokedAt = now.
    // totalAllocated must drop by the returned amount. Emit Revoked.
    // ------------------------------------------------------------
    function revoke(uint256 id) external onlyOwner nonReentrant {
        require(id > 0 && id <= scheduleCount, "unknown schedule");
        Schedule storage s = schedules[id];
        require(s.revocable, "not revocable");
        require(!s.revoked, "already revoked");
        uint256 vested = _vested(s);
        uint256 unvested = s.total - vested;
        s.revoked = true;
        s.revokedAt = uint64(block.timestamp);
        totalAllocated -= unvested;
        token.safeTransfer(owner(), unvested);
        emit Revoked(id, unvested);
    }

    // ------------------------------------------------------------
    // STEP 5 — housekeeping
    // withdrawUnallocated(to): owner only; sends balance - totalAllocated to `to`
    //   (rescues tokens sent by mistake / returned by nobody). Reverts if the amount is 0.
    // schedulesOf(beneficiary): ids of schedules currently owned by the address.
    // ------------------------------------------------------------
    function withdrawUnallocated(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        require(to != address(0), "zero recipient");
        uint256 balance = token.balanceOf(address(this));
        require(balance > totalAllocated, "nothing unallocated");
        amount = balance - totalAllocated;
        token.safeTransfer(to, amount);
    }

    function schedulesOf(address beneficiary) external view returns (uint256[] memory) {
        return _schedulesOf[beneficiary];
    }

    // ------------------------------------------------------------
    // BONUS — a beneficiary can hand the schedule to another address
    // Only the CURRENT beneficiary. New beneficiary != 0. Already released amount stays recorded.
    // schedulesOf must reflect the change (old owner no longer lists it, new owner does).
    // Emit ScheduleTransferred.
    // ------------------------------------------------------------
    function transferSchedule(uint256 id, address newBeneficiary) external {
        require(id > 0 && id <= scheduleCount, "unknown schedule");
        require(newBeneficiary != address(0), "zero beneficiary");
        Schedule storage s = schedules[id];
        address oldBeneficiary = s.beneficiary;
        require(msg.sender == oldBeneficiary, "not beneficiary");
        require(newBeneficiary != oldBeneficiary, "same beneficiary");
        uint256[] storage oldIds = _schedulesOf[oldBeneficiary];
        bool found;
        for (uint256 i = 0; i < oldIds.length; ++i) {
            if (oldIds[i] == id) {
                oldIds[i] = oldIds[oldIds.length - 1];
                oldIds.pop();
                found = true;
                break;
            }
        }
        require(found, "schedule index missing");
        s.beneficiary = newBeneficiary;
        _schedulesOf[newBeneficiary].push(id);
        emit ScheduleTransferred(id, oldBeneficiary, newBeneficiary);
    }

    function _vested(Schedule storage s) internal view returns (uint256) {
        uint256 t = s.revoked ? uint256(s.revokedAt) : block.timestamp;
        uint256 startTime = uint256(s.start);
        if (t < startTime + uint256(s.cliff)) return 0;
        if (t >= startTime + uint256(s.duration)) return s.total;
        return s.total * (t - startTime) / uint256(s.duration);
    }

}
