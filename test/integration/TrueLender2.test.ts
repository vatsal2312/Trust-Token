import { forkChain } from './suite'
import { setupDeploy } from 'scripts/utils'
import {
  MockUsdStableCoinOracle__factory,
  Erc20Mock,
  Erc20Mock__factory,
  ImplementationReference__factory,
  TrueFiPool2,
  TrueFiPool2__factory,
  TrueLender2,
  TrueLender2__factory,
  PoolFactory__factory,
  LoanFactory2,
  LoanFactory2__factory,
  LoanToken2,
  LoanToken2__factory,
} from 'contracts'
import { DAY, parseEth, parseTRU } from 'utils'
import fetch from 'node-fetch'
import { expect, use } from 'chai'
import { deployMockContract, MockContract, solidity } from 'ethereum-waffle'
import { utils, Wallet } from 'ethers'
import { TrueRatingAgencyV2Json } from 'build'
import { AddressZero } from '@ethersproject/constants'

use(solidity)

describe('TrueLender2', () => {
  const USDC_ADDRESS = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48'
  const USDT_ADDRESS = '0xdAC17F958D2ee523a2206206994597C13D831ec7'
  const TUSD_ADDRESS = '0x0000000000085d4780B73119b644AE5ecd22b376'
  const INCH_ADDRESS = '0x11111112542D85B3EF69AE05771c2dCCff4fAa26'
  const TUSD_HOLDER = '0xE662710B76BF0Eda532b109Ac2f6C1ca8688210b'
  const USDT_HOLDER = '0x2faf487a4414fe77e2327f0bf4ae2a264a776ad2'
  const OWNER = '0x52bc44d5378309EE2abF1539BF71dE1b7d7bE3b5'
  const provider = forkChain('https://eth-mainnet.alchemyapi.io/v2/Vc3xNXIWdxEbDOToa69DhWeyhgFVBDWl', [OWNER, TUSD_HOLDER, USDT_HOLDER])
  const owner = provider.getSigner(OWNER)
  const tusdHolder = provider.getSigner(TUSD_HOLDER)
  const usdtHolder = provider.getSigner(USDT_HOLDER)
  const deployContract = setupDeploy(owner)

  let usdcFeePool: TrueFiPool2
  let usdtLoanPool: TrueFiPool2
  let tusdLoanPool: TrueFiPool2
  let lender: TrueLender2
  let loanFactory: LoanFactory2
  let mockRatingAgency: MockContract
  let stkTru: Wallet
  let tusd: Erc20Mock
  let usdc: Erc20Mock
  let usdt: Erc20Mock
  let loan: LoanToken2

  beforeEach(async () => {
    stkTru = Wallet.createRandom()
    const poolFactory = await deployContract(PoolFactory__factory)
    const poolImplementation = await deployContract(TrueFiPool2__factory)
    const implementationReference = await deployContract(ImplementationReference__factory, poolImplementation.address)

    mockRatingAgency = await deployMockContract(owner, TrueRatingAgencyV2Json.abi)
    await mockRatingAgency.mock.getResults.returns(0, 0, parseTRU(50e6))

    lender = await deployContract(TrueLender2__factory)
    await lender.initialize(stkTru.address, poolFactory.address, mockRatingAgency.address, INCH_ADDRESS)

    await poolFactory.initialize(implementationReference.address, lender.address, AddressZero)

    await poolFactory.whitelist(USDC_ADDRESS, true)
    usdc = Erc20Mock__factory.connect(USDC_ADDRESS, owner)
    await poolFactory.createPool(usdc.address)
    usdcFeePool = TrueFiPool2__factory.connect(await poolFactory.pool(usdc.address), owner)
    await lender.setFeePool(usdcFeePool.address)

    await poolFactory.whitelist(TUSD_ADDRESS, true)
    tusd = Erc20Mock__factory.connect(TUSD_ADDRESS, owner)
    await poolFactory.createPool(tusd.address)
    tusdLoanPool = TrueFiPool2__factory.connect(await poolFactory.pool(tusd.address), owner)

    await poolFactory.whitelist(USDT_ADDRESS, true)
    usdt = Erc20Mock__factory.connect(USDT_ADDRESS, owner)
    await poolFactory.createPool(usdt.address)
    usdtLoanPool = TrueFiPool2__factory.connect(await poolFactory.pool(usdt.address), owner)

    loanFactory = await new LoanFactory2__factory(owner).deploy()
    await loanFactory.initialize(poolFactory.address, lender.address, AddressZero)
  })

  it('ensure max 1% swap fee slippage', async () => {
    const tx = await loanFactory.createLoanToken(tusdLoanPool.address, parseEth(100000), 1000, DAY * 365)
    const creationEvent = (await tx.wait()).events[0]
    const { contractAddress } = creationEvent.args

    loan = LoanToken2__factory.connect(contractAddress, owner)

    const oracle = await deployContract(MockUsdStableCoinOracle__factory)
    await tusdLoanPool.setOracle(oracle.address)

    await tusd.connect(tusdHolder).approve(tusdLoanPool.address, parseEth(100000))
    await tusdLoanPool.connect(tusdHolder).join(parseEth(100000))
    await lender.fund(loan.address)
    const debt = await loan.debt()
    await tusd.connect(tusdHolder).transfer(loan.address, debt)
    await loan.settle()

    const dataUrl = `https://api.1inch.exchange/v3.0/1/swap?disableEstimate=true&protocols=UNISWAP_V2,SUSHI&allowPartialFill=false&fromTokenAddress=${TUSD_ADDRESS}&toTokenAddress=${USDC_ADDRESS}&amount=${parseEth(1000)}&fromAddress=${lender.address}&slippage=1`
    const body = await (await fetch(dataUrl)).json()
    const data = body.tx.data

    await lender.reclaim(loan.address, data)
    expect(await usdcFeePool.balanceOf(stkTru.address)).to.gt(utils.parseUnits('100', 6).mul(98).div(100))
  })

  it('funds tether loan tokens', async () => {
    const tx = await loanFactory.createLoanToken(usdtLoanPool.address, 10_000_000, 1000, DAY * 365)
    const creationEvent = (await tx.wait()).events[0]
    const { contractAddress } = creationEvent.args

    loan = LoanToken2__factory.connect(contractAddress, owner)

    await usdt.connect(usdtHolder).approve(usdtLoanPool.address, 10_000_000)
    await usdtLoanPool.connect(usdtHolder).join(10_000_000)

    await expect(lender.fund(loan.address)).not.to.be.reverted
  })
})
