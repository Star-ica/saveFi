# SaveFi — decentralized group savings

HTML5 + CSS3 + vanilla JS + ethers.js (v5 UMD from cdnjs) + Solidity. No backend, DB, React or Node in the product.

## Layout
- `contracts/SaveFi.sol` — `SaveFiFactory` (factory + membership registry + admin/emergency) and `SaveFiCircle` (goal circle: contribution manager, goal vault, refunds) and `SavingsPot` (personal pot others can add to).
- `test/SaveFi.t.sol` — Foundry tests (Solidity). Foundry is a dev tool only.
- `web/index.html` — whole frontend (also published as the SaveFi artifact). Demo mode works with no chain.
- `SaveFi_Whitepaper.pdf`

## Test
    forge install foundry-rs/forge-std --no-commit
    forge test -vv                     # solc 0.8.24, optimizer on

## Deploy (any EVM chain hosting BOT / USDT)
    export RPC=<rpc-url>  PK=<deployer-key>
    # constructor arg = allowlisted payment tokens; address(0) = native coin (BOT if native)
    forge create contracts/SaveFi.sol:SaveFiFactory --rpc-url $RPC --private-key $PK \
      --constructor-args "[0x0000000000000000000000000000000000000000,<USDT_ADDRESS>]"
    # add an ERC-20 BOT later:
    cast send <FACTORY> "setTokenAllowed(address,bool)" <BOT_ADDRESS> true --rpc-url $RPC --private-key $PK

## Connect the frontend
Host `web/index.html` on any static host (or open it locally). Open **Admin → Settings**, paste the factory address and the USDT address (leave BOT blank if BOT is the native coin, otherwise paste its ERC-20 address), then press **Use live wallet**. Invite links look like `index.html#/join/<circleAddress>`.

## Notes
- Contracts were written without a compiler available in the authoring environment; run `forge build && forge test` and an independent audit before any mainnet use.
- Nothing executes automatically: withdrawals and refunds are transactions sent by the saver, the pot owner, or (for cancel/pause) the admin or factory owner.
# saveFi
