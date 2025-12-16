# Free Rider (Damn Vulnerable DeFi v4) 复盘笔记

> 目标：总结这关漏洞位置、利用链路，以及我在写 PoC 时犯的错与暴露出的知识缺口。

## 1. 这关的漏洞出现在什么地方？

Marketplace 的购买逻辑 `FreeRiderNFTMarketplace._buyOne` / `buyMany`。

### 1.1 `buyMany` 的支付校验方式有缺陷

文件：`src/free-rider/FreeRiderNFTMarketplace.sol`

- `buyMany(uint256[] calldata tokenIds)` 会循环调用 `_buyOne(tokenId)`。
- `_buyOne` 里用的是：

```solidity
if (msg.value < priceToPay) {
    revert InsufficientPayment();
}
```

问题点：
- `msg.value` 是 **整笔交易** 的 ETH，不会在 for-loop 中“自动扣减”。
- 因此，当你想在同一笔交易里买 6 个 NFT 时，只要 `msg.value` >= 单个 NFT 的价格（15 ETH），每一次 `_buyOne` 都会通过。

这等价于：
- “批量购买”没有校验总价，导致只付一次钱可以买多件。

### 1.2 `_buyOne` 付款对象计算错误（更致命）

在 `src/free-rider/FreeRiderNFTMarketplace.sol` 中：

1) 先转 NFT：

```solidity
_token.safeTransferFrom(_token.ownerOf(tokenId), msg.sender, tokenId);
```

2) 再支付卖家：

```solidity
payable(_token.ownerOf(tokenId)).sendValue(priceToPay);
```

问题点：
- 第 1 步执行后，`ownerOf(tokenId)` 已经变成买家 `msg.sender`。
- 第 2 步实际是在把 `priceToPay` 发送给 **买家自己**，而不是卖家。

后果：
- 买家几乎“零成本”拿走 NFT（钱会被退回）。
- Marketplace 合约自身的 ETH 余额会被持续掏空（因为它真的把钱转出去了）。

### 1.3 RecoveryManager 的 `onERC721Received` 并非漏洞点

文件：`src/free-rider/FreeRiderRecoveryManager.sol`

这里的检查（例如 `msg.sender` 必须是 NFT 合约、`tx.origin` 必须是 beneficiary、收到 6 个后支付 bounty）主要是：
- 限定只接受特定 NFT 合约回调。
- 要求最终交易发起者是 `beneficiary`（有点反模式，但用于题目约束）。
- 收齐 6 个 NFT 后把 bounty 打给 `data` 解码出的地址。

这些检查更多是关卡机制，不是“可被利用的漏洞主体”。

---

## 2. 正确的利用链路（抽象版）

这关常见解法是 Uniswap V2 flash swap（“闪电交换”）+ Marketplace 漏洞。

- 从 Uniswap V2 Pair flash swap 借出 WETH（因为池子是 `WETH/DVT`）。
- 在回调 `uniswapV2Call` 中把 WETH `withdraw` 成 ETH。
- 仅支付一次 15 ETH 调用 `marketplace.buyMany` 直接买走 6 个 NFT。
  - 同时因为支付给买家自己，ETH 会回流到攻击者/买家。
- 把 6 个 NFT 用 `safeTransferFrom(..., data=abi.encode(player))` 交给 `FreeRiderRecoveryManager`。
  - 触发 `onERC721Received` 累计到 6 后发放 bounty。
- 把部分 ETH wrap 回 WETH，并 `transfer` 回 Pair，归还本金+0.3% fee。
- 剩余 ETH 作为利润留给 player。

这里最关键的约束是：
- **借出的资产必须在同一笔 swap 的回调内归还**，否则 swap 会 revert。

---

## 3. 我在实现 PoC 时犯了哪些错误？

以下错误是典型“刚接触 flash swap/回调式协议交互”容易踩的坑。

### 3.1 把 `swap` 的 `to` 设置成 EOA（player）

错误思路：
- 以为 `pair.swap(..., to=player, data!=0)` 能把 token 发给 player，然后我在测试里继续执行后续逻辑。

问题：
- Uniswap V2 flash swap 的回调是对 `to` 地址发起外部调用 `uniswapV2Call`。
- EOA 没有代码，回调不会执行，因此无法在 swap 内归还。

体现的缺乏：
- 对 Uniswap V2 `swap` 的执行时序（transfer -> callback -> invariant check）理解不牢。

### 3.2 试图在 `swap` 之后再还款

错误思路：
- 在 `test_freeRider()` 的末尾计算 `amountToRepay` 再 wrap WETH。

问题：
- 只要你没在回调结束前把钱还给 Pair，`swap` 会在那一刻直接 revert。
- revert 发生后，后面的代码根本不会执行。

体现的缺乏：
- 对“原子性（atomicity）”与“回调内结算”这一 DeFi 交互模式理解不足。

### 3.3 直接调用 `recoveryManager.onERC721Received(...)`

错误思路：
- 以为我可以像普通函数一样手动调用它来“模拟收到 NFT”。

问题：
- `onERC721Received` 的语义是由 NFT 合约在 `safeTransferFrom` 过程中调用。
- `FreeRiderRecoveryManager` 里有：
  - `if (msg.sender != address(nft)) revert CallerNotNFT();`
- 你从测试/攻击合约直接调，它一定会 revert。

体现的缺乏：
- 对 ERC721 `safeTransferFrom` + `IERC721Receiver` 回调机制（谁调用谁、`msg.sender` 是谁）认知不完整。

### 3.4 `data` 参数编码类型不匹配

错误思路：
- 传入 `abi.encode("transfer")` 或其他 bytes。

问题：
- RecoveryManager 里把 `data` 解码成 `address`：
  - `address recipient = abi.decode(_data, (address));`
- 你必须传 `abi.encode(player)` 才能通过并把 bounty 打到 player。

体现的缺乏：
- 对 ABI 编码/解码“双方必须约定同一类型”的细节理解不牢。

### 3.5 常量表达式导致 `rational_const` 编译错误

错误现象：
- 写 `uint256 amountToRepay = (15 ether * 1000) / 997 + 1;` 报错

原因：
- Solidity 会把纯字面量表达式在编译期折叠成有理数常量（分数），无法隐式转成 `uint256`。

改法：
- 引入变量，强制走整数运算：

```solidity
uint256 amountBorrowed = 15 ether;
uint256 amountToRepay = (amountBorrowed * 1000) / 997 + 1;
```

体现的缺乏：
- 对 Solidity 常量折叠与类型系统（rational_const）的理解不够。

---

## 4. 我缺乏的隐含知识是什么？（详细展开）

### 4.1 Uniswap V2 flash swap 的执行模型

需要掌握：
- `pair.swap(amount0Out, amount1Out, to, data)`
  - 先把 token 转出去
  - 如果 `data.length > 0`，调用 `to.uniswapV2Call(...)`
  - 回调结束后检查 Pair 的余额是否满足手续费/常数乘积约束

你要在脑子里形成“这是一笔原子交易内的借贷/结算”的模型。

### 4.2 ETH 与 WETH 的边界

需要掌握：
- Pair 里永远是 ERC20（WETH），不是原生 ETH。
- `WETH.deposit()` 是把 ETH -> WETH
- `WETH.withdraw()` 是把 WETH -> ETH

很多 DeFi 合约用 WETH，但一些业务合约（像本题 marketplace）收原生 ETH，桥接点就在 `deposit/withdraw`。

### 4.3 ERC721 safe transfer 与 receiver 回调

需要掌握：
- `safeTransferFrom` 到合约 → NFT 合约会调用接收合约的 `onERC721Received`。
- 在 `onERC721Received` 内：
  - `msg.sender` 是 NFT 合约地址
  - `operator/from/tokenId/data` 各自含义不同

因此，如果某个接收合约校验了 `msg.sender == nft`，你就不可能通过“手动调用”绕过。

### 4.4 ABI 编码/解码的契约

需要掌握：
- `abi.encode(address)` 与 `abi.encode(string)` 得到的 bytes 完全不同。
- 解码时类型必须和编码时一致，否则 revert。

在题目里：
- `data` 被用作“赏金收款人地址”的传递通道，因此必须 encode address。

### 4.5 Solidity 的常量折叠与数值类型

需要掌握：
- 纯字面量表达式会在编译期折叠成 `rational_const`（分数）。
- 遇到这种情况：
  - 用变量承接中间值
  - 或拆成两步
  - 或显式转换类型

---

## 5. 小结

- **漏洞点**：Marketplace 支付逻辑错误（批量购买校验错误 + 支付对象取错导致退钱给买家）。
- **利用点**：用 Uniswap V2 flash swap 提供短期流动性，原子化完成买 NFT、交付领 bounty、还款。
- **学习点**：回调式协议交互（flash swap / receiver hook）必须理解“谁调用谁、何时检查、何时结算”。
