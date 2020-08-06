pragma solidity =0.6.12;

interface TimeswapFlashInterface {
    function lend(
        address _sender,
        uint256 bond,
        uint256 _insurance,
        bytes calldata _data
    ) external;

    function borrow(
        address _sender,
        uint256 _token,
        bytes calldata _data
    ) external;

    function withdraw(
        address _sender,
        uint256 _token,
        uint256 _collateral,
        bytes calldata _data
    ) external;

    function pay(
        address _sender,
        uint256 _collateral,
        bytes calldata _data
    ) external;
}
