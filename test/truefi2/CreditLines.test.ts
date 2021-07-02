import {
  beforeEachWithFixture,
  createApprovedLoan,
  DAY,
  parseEth,
  setupTruefi2,
  timeTravel as _timeTravel,
} from 'utils'
import { Deployer, setupDeploy } from 'scripts/utils'
import {
  CreditLinesPool, CreditLinesPool__factory, ImplementationReference__factory,
  LoanFactory2,
  LoanToken2,
  MockTrueCurrency, OwnedProxyWithReference, OwnedProxyWithReference__factory,
  Safu,
  StkTruToken, TrueFiPool2,
  TrueLender2,
  TrueRatingAgencyV2,
} from 'contracts'
import { MockProvider } from 'ethereum-waffle'
import { Wallet } from 'ethers'

describe('Credit lines POC', () => {
  let provider: MockProvider
  let owner: Wallet
  let borrower: Wallet
  let tusd: MockTrueCurrency
  let tru: MockTrueCurrency
  let stkTru: StkTruToken
  let tusdPool: TrueFiPool2
  let creditLinesPool: CreditLinesPool
  let loanFactory: LoanFactory2
  let lender: TrueLender2
  let rater: TrueRatingAgencyV2
  let loan: LoanToken2
  let safu: Safu
  let deployContract: Deployer

  let timeTravel: (time: number) => void
  const joinAmount = parseEth(1e7)

  beforeEachWithFixture(async (wallets, _provider) => {
    [owner, borrower] = wallets
    deployContract = setupDeploy(owner)
    timeTravel = (time: number) => _timeTravel(_provider, time)
    provider = _provider

    ;({ stkTru,
      tru,
      standardToken: tusd,
      rater,
      lender,
      standardPool: tusdPool,
      loanFactory,
      safu,
    } = await setupTruefi2(owner))

    loan = await createApprovedLoan(rater, tru, stkTru, loanFactory, borrower, tusdPool, 500000, DAY, 1000, owner, provider)

    const creditLinesPoolImpl = await new CreditLinesPool__factory(owner).deploy()
    const reference = await new ImplementationReference__factory(owner).deploy(creditLinesPoolImpl.address)
    const proxy = OwnedProxyWithReference__factory.connect(tusdPool.address, owner)
    await proxy.changeImplementationReference(reference.address)
    creditLinesPool = CreditLinesPool__factory.connect(tusdPool.address, owner)

    await tusd.mint(owner.address, parseEth(1e7))
    await tusd.approve(tusdPool.address, joinAmount)
    await tusdPool.join(joinAmount)
  })

  it('test', async () => {
    await creditLinesPool.borrowCreditLine(parseEth(1e6), borrower.address)
    console.log((await creditLinesPool.interest(borrower.address)).toString())
    console.log((await creditLinesPool.rate(borrower.address)).toString())
    console.log((await creditLinesPool.utilization()).toString())
    await timeTravel(1000)
    console.log((await creditLinesPool.interest(borrower.address)).toString())
    console.log((await creditLinesPool.rate(borrower.address)).toString())
    console.log((await creditLinesPool.utilization()).toString())
    await creditLinesPool.checkpoint()
    await timeTravel(1000)
    console.log((await creditLinesPool.interest(borrower.address)).toString())
    console.log((await creditLinesPool.rate(borrower.address)).toString())
    console.log((await creditLinesPool.utilization()).toString())
  })

  it('HEAVY TEST', async () => {
    for (let i = 1; i < 50; i++) {
      await creditLinesPool.borrowCreditLine(parseEth(1e5), Wallet.createRandom().address)
    }
    const tx = await (await creditLinesPool.checkpoint()).wait()
    console.log(tx.gasUsed.toString())
  }).timeout(1000000000)
})
