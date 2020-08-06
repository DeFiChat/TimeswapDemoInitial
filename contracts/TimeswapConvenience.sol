pragma solidity =0.6.12;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./SafeMath256.sol";
import "./SafeMath128.sol";
import "./TimeswapPool.sol";

contract TimeswapConvenience {
    using SafeMath256 for uint256;
    using SafeMath128 for uint128;
    using SafeERC20 for IERC20;
    
    function lend(TimeswapPool _timeswapPool, uint128 _token, uint128 _insurance, address _to) external {
        
        // (uint256 _tokenBalance, uint256 _collateralBalance) = _timeswapPool.viewBalance();
        
        (uint112 _tokenReserve, uint112 _insuranceReserve, uint112 _interestReserve,) = _timeswapPool.viewReserves();
        
        // uint128 __token = uint128(_tokenBalance.sub(uint256(_tokenReserve))).add(_token);
        // uint128 __insurance = uint128(_collateralBalance.sub(uint256(_insuranceReserve))).add(_insurance);
        // if (_tokenBalance > _tokenReserve)
        
        IERC20(_timeswapPool.token()).transferFrom(msg.sender, address(_timeswapPool), uint256(_token));

        uint128 yMax = uint128(uint256(_token).mul(uint256(_interestReserve)).div(uint256(_tokenReserve).add(uint256(_token))));
        uint128 zMax = uint128(uint256(_token).mul(uint256(_insuranceReserve)).div(uint256(_tokenReserve).add(uint256(_token))));
        require(zMax >= _insurance, "Overflow");
        uint128 y = uint128(uint256(yMax).mul(uint256(zMax.sub(_insurance))).div(uint256(zMax)));
        require(yMax >= y, "Overflow");
        uint128 _bond = _token.add(y);
        
        _timeswapPool.lend(_insurance, _bond, zMax, yMax, _to, new bytes(0));
    }
    
    function borrow(TimeswapPool _timeswapPool, uint128 _token, uint128 _collateral, address _to) external {
        // (uint256 _tokenBalance, uint256 _collateralBalance) = _timeswapPool.viewBalance();
        
        (uint112 _tokenReserve, uint112 _insuranceReserve, uint112 _interestReserve,) = _timeswapPool.viewReserves();
        
        // uint128 __token = uint128(_tokenBalance.sub(uint256(_tokenReserve))).add(_token);
        // uint128 __insurance = uint128(_collateralBalance.sub(uint256(_insuranceReserve))).add(_collateral);
        
        IERC20(_timeswapPool.collateral()).transferFrom(msg.sender, address(_timeswapPool), uint256(_collateral));
    
        uint128 yMax = uint128(uint256(_token).mul(uint256(_interestReserve)).div(uint256(_tokenReserve).sub(uint256(_token))).add(1)); // round up
        uint128 zMin = uint128(uint256(_token).mul(uint256(_insuranceReserve)).div(uint256(_tokenReserve).sub(uint256(_token))).add(1)); // round up
        require(zMin <= _collateral, "Overflow");
        uint128 y = uint128(uint256(yMax).mul(uint256(zMin)).div(uint256(_collateral))).add(1); // round up
        require(yMax >= y, "Overflow");
        uint128 _bond = _token.add(y);
        
        _timeswapPool.borrow(_token, _bond, zMin, yMax, _to, new bytes(0));
    }
    
    function withdraw(TimeswapPool _timeswapPool, uint128 _bond, uint128 _insurance, address _to) external {
        _withdraw(_timeswapPool, _bond, _insurance, _to);
    }
    
    function withdrawAll(TimeswapPool _timeswapPool, address _to) external {
        (uint128 _bond, uint128 _insurance) = _timeswapPool.depositOf(_to);
        _withdraw(_timeswapPool, _bond, _insurance, _to);
    }
    
    function _withdraw(TimeswapPool _timeswapPool, uint128 _bond, uint128 _insurance, address _to) internal {
        (,, uint112 _interestReserve,) = _timeswapPool.viewReserves(); 
        
        uint256 _tokenBalance = IERC20(_timeswapPool.token()).balanceOf(address(_timeswapPool)).sub(uint256(_interestReserve));
        uint256 _collateralBalance = IERC20(_timeswapPool.collateral()).balanceOf(address(_timeswapPool));
        
        (uint128 _bondBalance, uint128 _insuranceBalance) = _timeswapPool.totalDeposit();
        (uint128 _bondWithdrawn, uint128 _insuranceWithdrawn) = _timeswapPool.totalWithdrawn();
        
        uint128 _tokenOut = uint128(_tokenBalance.mul(uint256(_bond)).div(uint256(_bondBalance).sub(uint256(_bondWithdrawn))));
        uint128 _collateralOut = uint128(_collateralBalance.mul(uint256(_insurance)).div(uint256(_insuranceBalance).sub(uint256(_insuranceWithdrawn))));
        
        _timeswapPool.withdraw(_bond, _insurance, _tokenOut, _collateralOut, _to, new bytes(0));
    }
    
    function pay(TimeswapPool _timeswapPool, uint128 _debt, uint256 _index, address _to) external {
        _pay(_timeswapPool, _debt, _index, _to);
    }
    
    function payAll(TimeswapPool _timeswapPool, uint256 _index, address _to) external {
        (uint128 _debt,) = _timeswapPool.loanOf(_to, _index);
        _pay(_timeswapPool, _debt, _index, _to);
    }
    
    function _pay(TimeswapPool _timeswapPool, uint128 _debt, uint256 _index, address _to) internal {
        (uint128 _debtBalance, uint128 _collateralBalance) = _timeswapPool.loanOf(_to, _index);
        
        uint128 _collateralOut = uint128(uint256(_collateralBalance).mul(uint256(_debt)).div(uint256(_debtBalance)));
        
        IERC20(_timeswapPool.token()).transferFrom(msg.sender, address(_timeswapPool), uint256(_debt));
        
        _timeswapPool.pay(_collateralOut, _index, _to, new bytes(0));
    }
    
}