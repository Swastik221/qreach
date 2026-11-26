#!/bin/bash
# Reset the local anvil chain to genesis, redeploy QREACH with mocks, register riya.qie.
set -e
export PATH="$PATH:$HOME/.foundry/bin"
R=http://127.0.0.1:8545
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
cast rpc anvil_reset --rpc-url $R >/dev/null
cd "$(dirname "$0")/../../contracts"
forge script script/Deploy.s.sol --rpc-url $R --broadcast --legacy --with-gas-price 10gwei --private-key $K0 >/dev/null
cast send 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 "register(string,address)" riya 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --rpc-url $R --private-key $K0 >/dev/null
cast call 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 "nextId()(uint256)" --rpc-url $R
