var DaiTSDemo = artifacts.require("SampleERC20");
var FileTSDemo = artifacts.require("SampleERC20");
var TimeswapPool = artifacts.require("TimeswapPool");
var TimeswapConvenience = artifacts.require("TimeswapConvenience");

module.exports = async function (deployer) {
    let addr = await web3.eth.getAccounts();
    await deployer.deploy(DaiTSDemo, "Dai TS Demo", "DAI");
    await deployer.deploy(FileTSDemo, "Filecoin TS Demo", "FILE");
    await deployer.deploy(TimeswapPool);
    await deployer.deploy(TimeswapConvenience);
    //let instance = await MyToken.deployed();
    //await instance.transfer(MyTokenSale.address, process.env.INITIAL_TOKENS);
}