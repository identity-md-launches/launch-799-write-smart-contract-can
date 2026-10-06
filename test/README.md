# Vault test coverage

Run `forge build` and `forge test` from the repository root. The suite uses the
already vendored dependencies and requires no RPC, environment variables, FFI,
or additional downloads once the pinned compiler is available.

The original deployment, administration, asset, and invariant tests are retained.
Fuzz run counts are set in the test source. The existing conservation fuzz test
now accepts `uint256` seeds so its intended 100 IMD upper bound is reachable;
`uint64` could represent only about 18.45 IMD at 18 decimals.

| Added coverage | Property |
| --- | --- |
| `AdversarialVault.t.sol` mixed deposits | Different senders and all four assets consume one $10,000 budget. One extra unit of any asset is rejected atomically. Withdrawing USDC allows the same dollar value to be deposited as USDT. |
| IMD decimal boundaries | One configured whole IMD is $9 at each supported decimal setting. The largest admissible raw balance succeeds; one more unit fails. Full withdrawal restores capacity. |
| Transfer fees | Only the actual receipt consumes capacity. Rejected deposits undo sender debits, allowance spending, and token fee burns. |
| Policy context | Policies receive the actual sender, asset, received amount, and combined value after receipt, including through `receive()`. |
| Authorization and callbacks | Beneficiary `tx.origin` gives an intermediary no authority. A callback executing as the beneficiary cannot reenter any withdrawal entry point. |
| Pathological donated balance | Valuation overflow rejects deposits without losing ETH; the beneficiary can still withdraw the overflowing token balance and other funds. |
| `VaultStateMachine.t.sol` custody | An independent ledger of deposits, donations, and payouts matches each held asset. Only the fixed beneficiary gains withdrawals; each depositor loses exactly its contributed amount. |
| State machine | Random sequences mix three depositors, zero/dust/boundary amounts, both ETH entry points, partial/full/excess withdrawals, unauthorized withdrawals, donations, pause/unpause, two-step ownership, and open/restrictive/reverting/invalid policies. Exact expected reverts and allowance rollback are checked. |
| Withdrawal liveness | After each random campaign, the beneficiary drains all remaining assets without first changing ownership, pause, or policy. |

The new state machine runs 256 sequences of depth 96 with handler failures fatal.
Its expected balances, capacity, roles, pause state, and policy are tracked
independently of the vault getters. A deterministic sequence also exercises the
handler's ownership handover, policy rejection, donation, recovery, and reopening
paths. The retained deposit-only cap campaign runs 256 sequences of depth 64.
Every fuzz property runs 1,000 examples. No fuzz input is discarded with
`vm.assume`.

The cap applies to accepted deposits. ERC20 transfers and forced ETH can arrive
without executing vault admission checks. The state machine tracks these donations
separately, checks that they consume capacity, and requires their recovery; the
original invariant without donations asserts that holdings stay within the cap.
Forced ETH is modeled with paired `vm.deal` balance changes. The invariant tokens
are fee-free; adversarial token behavior is exercised by the individual tests.

This is a collection vault with a fixed beneficiary, not a depositor redemption
system. Conservation checks therefore credit withdrawals to the beneficiary.
The existing upgrade mechanism replaces admission policies; these tests do not
claim that custody bytecode is upgradeable.

No live Ethereum fork is used. Local stand-ins cover six-decimal stablecoins,
USDT's empty transfer return data, configurable IMD unit scaling, transfer fees,
failed transfers, and callbacks. They do not establish the deployed tokens'
identity, metadata, issuer restrictions, or current upgrade behavior. Mainnet
code/decimals verification and integration runs against the actual configured
USDT/USDC contracts and pinned IMD address remain outstanding.
