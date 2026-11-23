# Token Vesting Vault

A Solidity smart contract for ERC-20 token vesting.

## Features

- Create token vesting schedules
- Cliff and linear token vesting
- Release vested tokens to beneficiaries
- Revoke schedules and return unvested tokens
- Withdraw unallocated tokens
- Transfer schedules to another beneficiary

## Technologies

- Solidity ^0.8.20
- OpenZeppelin Contracts 5.x
- Remix IDE

## How to Run

1. Open Remix IDE.
2. Compile `VestingVault.sol`.
3. Deploy an ERC-20 token.
4. Deploy VestingVault with the token address.
5. Transfer tokens to VestingVault.
6. Create a vesting schedule.
7. Check `vestedAmount` and `releasable`.
8. Call `release` to claim unlocked tokens.

## Project Status

Smart contract implementation completed. Automated tests are pending.
