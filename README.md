# Capped asset vault

`CappedAssetVault` accepts ETH, USDT, USDC and the IMD token at
`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`. The combined **current balance** is
limited to **$10,000** through its deposit entry points. ETH is valued at exactly
$2,600, IMD at exactly $9, and both stablecoins at exactly $1. Withdrawals restore
deposit capacity. This is a collection vault: depositing creates no shares,
refund entitlement, or personal balance that the sender can redeem.

Only `0x047f606fd5b2baa5f5c6c4ab8958e45cb6b054b7` can initiate a withdrawal. Every
withdrawal pays that same address. It can withdraw any positive amount up to the
available balance, including the full balance, while deposits are paused and
after any policy upgrade. The administration owner is a separate, explicit
constructor argument; ownership alone gives no withdrawal permission.

## Build and tests

```sh
forge build
forge test
forge fmt --check
```

The project pins Solidity **0.8.26**, Cancun EVM, optimizer 200 runs and
`bytecode_hash = "none"`. Dependencies are vendored as ordinary source files;
see [DEPENDENCIES.md](DEPENDENCIES.md). With Foundry and the pinned compiler
installed, these commands need no network, environment variables, keys, FFI,
or filesystem cheatcode permissions. Tests do not fork a live chain.

The submitted tests cover mixed-asset and exact cap boundaries, smallest-unit
deposits, rollback, no-return/false-return/malformed ERC20s, fees, failed payments,
reentrancy, unsolicited balances, owner/beneficiary separation, pause semantics,
policy upgrades, two-step ownership, factory deployment, runtime opcode/size
restrictions, fuzzed conservation, and stateful deposit/withdraw/pause/upgrade
sequences. `test/Deployment.t.sol` rehearses the same constructor and runtime
restrictions as the supplied protected check without its external environment.

Local validation with Foundry 1.8.4 passed `forge build`, all 52 reported tests,
and `forge fmt --check`; the suite also passed with an empty environment and
`--offline`. Each invariant run exercised 8,192 calls. Two build lint warnings
remain visible: the policy assignment warning overlooks the immediately following
`PolicyUpgraded` event, and the ETH-send warning overlooks the reentrancy guard
held by both calling entry points. Tests cover the upgrade event and rejection
of a beneficiary callback attempting a second withdrawal.

## Deposits and accounting

- `depositETH()` is payable. Sending ETH with empty calldata calls the same
  checks. Use a normal transaction/call with sufficient gas; `send`/`transfer`
  with the 2,300 gas stipend is insufficient. Unknown selectors revert.
- For ERC20s, approve the **vault**, then call `depositToken(asset, rawAmount)`.
  Only the configured USDT/USDC and pinned IMD addresses are accepted. Approve
  the intended deposit amount; deposits never spend anyone else's allowance.
- Zero deposits revert. A deposit exceeding the cap reverts in full, including
  its token transfer and allowance consumption. The cap is shared across all
  senders and all four assets, not per sender, asset, or transaction.
- `totalValueUsd()` and `remainingCapacityUsd()` return dollars scaled by `1e18`.
  Valuation is `wei * 2600 + usdtRaw * 1e12 + usdcRaw * 1e12 +
  imdRaw * 9 * 10**(18 - imdDecimals)`. No division or rounding loses dust.
  The supported decimal range for IMD is 0 through 18; stablecoins must have 6.
- The vault measures the actual received token amount, supports USDT's empty
  transfer return data through OpenZeppelin SafeERC20, and values a transfer fee
  using the post-transfer balance. Zero receipts and unexpected increases above
  the requested amount revert. Rebasing/reflection tokens are not supported.
  Deposited events contain actual receipts; withdrawal amounts are token units
  requested from the token, so any token-imposed outgoing fee reduces the payee's
  receipt. The configured token contracts must report honest balances/transfers.

An absolute balance ceiling is impossible for an EVM receiver: someone can
transfer ERC20s directly without calling it, and ETH can arrive without executing
`receive`. Such unsolicited funds may exceed $10,000 or arrive while paused.
They count in the next valuation; further controlled deposits revert until the
beneficiary withdraws enough. A direct transfer emits no vault `Deposited` event.
Frontends must use the deposit entry points and warn against direct token sends.
The tests model forced ETH by changing the balance with `vm.deal`.

## Withdrawal API

| Function | Effect |
| --- | --- |
| `withdrawETH(amount)` | Pays the fixed beneficiary the requested wei amount. |
| `withdrawToken(asset, amount)` | Pays the fixed beneficiary the requested raw token amount. |
| `withdrawAll(asset)` | Withdraws one asset's full balance; `address(0)` means ETH. |

All three require `msg.sender` to be the fixed beneficiary. Zero/over-balance
withdrawals revert. `withdrawToken` also recovers accidentally sent unsupported
ERC20s to that beneficiary. There is no owner sweep, arbitrary recipient, external
approval, arbitrary execution, or migration function. Each asset can be withdrawn
independently, so a broken token or policy does not block ETH or other tokens.
Actual transfers remain subject to issuer blacklists/pauses and the beneficiary's
ability to accept ETH. A failed transfer reverts and can be retried.

## Owner, pausing and upgrade model

The supplied protected runtime check forbids `DELEGATECALL`, `CALLCODE` and
`SELFDESTRUCT`. Accordingly this project implements **replaceable deposit policy
logic**, with an immutable custody contract. This is not a UUPS/transparent proxy
or unrestricted replacement of all vault code. The same vault address, funds and
administration state survive policy changes. A custody-code change would require
a newly reviewed deployment and funds moved by the fixed beneficiary itself.

`OpenDepositPolicy` admits all deposits that pass the vault's checks. A future
`IDepositPolicy` can add admission rules, such as an allowlist or a minimum deposit.
The owner performs an upgrade as follows:

1. Deploy and review the replacement policy. It must expose the expected
   `policyId()` and `allowsDeposit(vault, depositor, asset, amount, totalUsdWad)`.
2. Call `pause()` on the vault. Withdrawals continue to work.
3. Call `upgradeTo(newPolicy)`; the vault checks code presence and policy ID.
4. Confirm the `PolicyUpgraded` event and policy address, then call `unpause()`.

Policies are invoked by **STATICCALL**, have no access to vault storage or token
approvals, receive no funds, and cannot change the cap, prices, supported assets,
or beneficiary. The interface ID is a compatibility check, not a security review.
A malicious/broken policy can deny deposits or waste their transaction gas; the
owner can replace it, and withdrawals do not call it. Pause/unpause and upgrade
rights are immediate and have no timelock. Monitoring and protecting the owner
account are operational responsibilities.

Ownership transfers use `transferOwnership(candidate)` followed by
`acceptOwnership()` from that candidate. The existing owner remains active until
acceptance. Zero/self candidates and ownership renunciation are rejected. Owner
changes never change withdrawal rights. The beneficiary is intentionally fixed:
loss of its signing capability cannot be repaired by the owner.

## Deployment parameters and handoff

Target **Ethereum mainnet (chain ID 1)**. Deploy these two application contracts
in this order using nonpayable constructors and zero deployment value:

| Contract | Constructor arguments in ABI order |
| --- | --- |
| `OpenDepositPolicy` | None |
| `CappedAssetVault` | `initialOwner`, `usdt`, `usdc`, `imdDecimals_`, `initialPolicy` |

`initialOwner` must be the launch's actual owner (`$owner` in the deployment
handoff), not the factory or a worker-selected wallet. Set `initialPolicy` to the
previously deployed `OpenDepositPolicy` (`$contract:OpenDepositPolicy`). Both
constructors finish configuration immediately; no initializer or later setup
transaction is needed. The vault constructor does not create other contracts.

Expected mainnet token configuration, **requiring live verification before use**:

| Parameter | Expected value | Status |
| --- | --- | --- |
| `usdt` | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | Configured address, expected 6 decimals. |
| `usdc` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | Configured address, expected 6 decimals. |
| `imdDecimals_` | `18` | Expected metadata for the task-pinned IMD address. |
| `IMD` | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | Fixed by the task; cannot be changed. |
| `WITHDRAWER` | `0x047f606fd5b2baa5f5c6c4ab8958e45cb6b054b7` | Fixed by the task; cannot be changed. |

No `.imd/reads/network.json` was supplied. Public RPC reads attempted during
implementation returned HTTP 403, so no live code, symbol, or decimals verification
is claimed. Constructor token arguments deliberately make no external token calls;
deployment rehearsals can therefore run without a fork. A wrong token address or
decimal parameter is a deployment error and cannot be repaired by a policy upgrade.
The deployer must check `cast chain-id`, `cast code`, `symbol()(string)` and
`decimals()(uint8)` for each token on a trusted mainnet RPC, record the block used,
and confirm the intended IMD identity before deploying. The task pins the IMD
address; token display symbols are not authorization. Missing code or reverting
balance reads block deposits; a wrong decimal setting instead misvalues holdings,
which is why verification is required. Withdrawals avoid unrelated tokens.

Tether's [official supported protocols page](https://tether.to/en/supported-protocols/)
lists the Ethereum USDT address and documents its empty transfer return data.
The other address/decimal expectations above are configuration assumptions, not
a substitute for the deployer's live verification.

`script/Deploy.s.sol` offers `run(owner, usdt, usdc, imdDecimals)` as a tested local
rehearsal. It reads no environment, holds no keys, and never broadcasts. The project
factory should deploy the two application artifacts directly. `launch.json` is
left to the separate manifest handoff described in the assignment; that handoff
must use the verified values above and only these two application contracts.

Before funded use, the deployer must verify the source/constructor parameters,
confirm beneficiary control and the owner account, perform an independent
adversarial review, and publish the confirmed vault address. Operators should
monitor deposits, withdrawals, unsolicited balances, owner/policy changes and
token issuer restrictions. Fixed prices intentionally ignore market price changes
and stablecoin depegs. The cap is a fixed-price accounting limit, not a guarantee
that market exposure stays below $10,000. Local tests are not a live integration
test or security audit; Slither/Mythril were not run and no transaction was sent.
