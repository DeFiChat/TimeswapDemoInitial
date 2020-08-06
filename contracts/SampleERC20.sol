pragma solidity =0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SampleERC20 is ERC20 {
    constructor(string memory _name, string memory _symbol)
        public
        ERC20(_name, _symbol)
    {}

    function mint(address _to, uint256 _value) external {
        _mint(_to, _value);
    }
}
