pragma solidity =0.6.12;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./SafeMath256.sol";
import "./SafeMath128.sol";
import "./TimeswapFlashInterface.sol";
import "./UQ112x112.sol";
import "./SampleERC20.sol";

contract TimeswapPool is ReentrancyGuard {
    using SafeMath256 for uint256;
    using SafeMath128 for uint128;
    using UQ112x112 for uint224;
    using SafeERC20 for IERC20;

    // MODEL

    // Factory address
    // Immutable after initialization
    address public factory;

    // Maturity time
    // Immutable after initialization
    uint256 public maturity;

    // External ERC20 token contracts
    // Immutable after initialization
    address public token;
    address public collateral;

    // Deposit model
    struct Deposit {
        uint128 bond;
        uint128 insurance;
    }
    Deposit public totalDeposit;
    Deposit public totalWithdrawn;
    mapping(address => Deposit) public depositOf;

    // Loan model
    struct Loan {
        uint128 debt;
        uint128 collateral;
    }
    Loan public totalLoan;
    Loan public totalPaid;
    mapping(address => Loan[]) public loanOf;

    // Reserve model
    uint112 private tokenReserve;
    uint112 private insuranceReserve;
    uint32 private blockTimestampLast;

    // Stored price for decentralized oracle feature
    uint256 public interestPriceCumulativeLast;
    uint256 public insurancePriceCumulativeLast;

    // INIT

    // Called once on deployment by the factory contract
    function initialize(
        address _token,
        address _collateral,
        uint256 _maturity
    ) external {
        require(factory == address(0), "Timeswap: Forbidden");
        factory = msg.sender;
        token = _token;
        collateral = _collateral;
        maturity = _maturity;
        // Timeswap Demo
        uint256 tokenInitial = 100000 * (10**18);
        uint256 collateralInitial = 400 * (10**18);
        uint256 interestInitial = 80000 * (10**18);
        SampleERC20(token).mint(address(this), tokenInitial);
        SampleERC20(collateral).mint(
            address(this),
            collateralInitial.add(collateralInitial)
        );
        tokenReserve = uint112(tokenInitial);
        insuranceReserve = uint112(collateralInitial);
        totalDeposit = Deposit(
            uint128(interestInitial.add(tokenInitial)),
            uint128(collateralInitial)
        );
        depositOf[msg.sender] = Deposit(
            uint128(interestInitial.add(tokenInitial)),
            uint128(collateralInitial)
        );
        totalLoan = Loan(
            uint128(tokenInitial),
            uint128(collateralInitial.add(collateralInitial))
        );
        loanOf[msg.sender].push(
            Loan(
                uint128(tokenInitial),
                uint128(collateralInitial.add(collateralInitial))
            )
        );
    }

    // EVENT

    event Lend(
        address indexed sender,
        uint128 tokenIn,
        uint128 interestOut,
        uint128 insuranceOut,
        address indexed to
    );
    event Borrow(
        address indexed sender,
        uint128 tokenOut,
        uint128 interestIn,
        uint128 collateralIn,
        address indexed to
    );
    event Withdraw(
        address indexed sender,
        uint128 tokenOut,
        uint128 collateralOut,
        uint128 bondIn,
        uint128 insuranceIn,
        address indexed to
    );
    event Pay(
        address indexed sender,
        uint128 tokenIn,
        uint128 __collateralOut,
        uint256 _index,
        address indexed _to
    );
    event Sync(uint112 tokenReserve, uint112 insuranceReserve);

    // VIEW

    function viewReserves()
        public
        view
        returns (
            uint112 _tokenReserve,
            uint112 _insuranceReserve,
            uint112 _interestReserve,
            uint32 _blockTimestampLast
        )
    {
        _tokenReserve = tokenReserve;
        _insuranceReserve = insuranceReserve;
        _interestReserve = uint112(
            uint128(tokenReserve).add(totalLoan.debt).sub(totalDeposit.bond)
        );
        _blockTimestampLast = blockTimestampLast;
    }

    function viewBalance()
        public
        view
        returns (uint256 _tokenBalance, uint256 _insuranceBalance)
    {
        _tokenBalance = IERC20(token).balanceOf(address(this)).sub(
            uint256(totalPaid.debt)
        );
        _insuranceBalance = IERC20(collateral)
            .balanceOf(address(this))
            .add(uint256(totalPaid.collateral))
            .sub(uint256(totalDeposit.insurance));
    }

    // UPDATE

    function lend(
        uint128 _insuranceOut,
        uint128 _bondOut,
        uint128 _insuranceOutMax,
        uint128 _interestOutMax,
        address _to,
        bytes calldata _data
    ) external nonReentrant() {
        // Initial require
        require(block.timestamp < maturity, "Timeswap : Bond Matured");
        require(
            _bondOut > 0 || _insuranceOut > 0,
            "Timeswap : Insufficient Output"
        );
        require(
            _interestOutMax > 0 || _insuranceOutMax > 0,
            " Timeswap : Insufficient Output Max Amount"
        );

        // Get reserves
        (
            uint112 _tokenReserve,
            uint112 _insuranceReserve,
            uint112 _interestReserve,

        ) = viewReserves();

        // Optimistically mint tokens for flash feature
        require(_to != address(this), "Timesap : Invalid To");
        depositOf[_to] = Deposit(
            depositOf[_to].bond.add(_bondOut),
            depositOf[_to].insurance.add(_insuranceOut)
        );
        totalDeposit = Deposit(
            totalDeposit.bond.add(_bondOut),
            totalDeposit.insurance.add(_insuranceOut)
        );
        if (_data.length > 0)
            TimeswapFlashInterface(_to).lend(
                msg.sender,
                _bondOut,
                _insuranceOut,
                _data
            ); // call any arbitrary code for flash feature

        // Get balance
        uint256 _tokenBalance = IERC20(token).balanceOf(address(this)).sub(
            uint256(totalPaid.debt)
        );
        uint256 _insuranceBalance = IERC20(collateral)
            .balanceOf(address(this))
            .add(uint256(totalPaid.collateral))
            .sub(uint256(totalDeposit.insurance));

        // Get token amount in
        uint256 _tokenIn = _tokenBalance > _tokenReserve
            ? _tokenBalance.sub(uint256(_tokenReserve))
            : 0;
        require(_tokenIn > 0, "Timeswap : Insufficient Input");

        // Get interest out
        uint128 _interestOut = _bondOut.sub(uint128(_tokenIn));
        uint128 __insuranceOut = _insuranceOut; // Avoid stacks too deep error
        require(
            _interestOut > 0 || __insuranceOut > 0,
            "Timeswap : Insufficient Output"
        );
        require(
            _insuranceOut <= _insuranceOutMax &&
                _interestOut <= _interestOutMax,
            "Timeswap : Overflow Max"
        );
        require(
            _insuranceOut < _insuranceReserve &&
                _interestOut < _insuranceReserve,
            "Timeswap : Insufficient Reserve"
        );

        // Constant Product
        uint256 _insuranceDifference = uint256(
            _insuranceOutMax.sub(__insuranceOut)
        );
        uint256 _interestDifference = uint256(
            _interestOutMax.sub(_interestOut)
        );
        uint128 __interestOutMax = _interestOutMax; // avoid stacks too deep error
        uint256 _insuranceMax = _insuranceBalance.sub(_insuranceDifference);
        uint256 _interestMax = uint256(_interestReserve).sub(
            uint256(__interestOutMax)
        );
        require(
            _tokenBalance.mul(_insuranceMax) >=
                uint256(_tokenReserve).mul(uint256(_insuranceReserve)),
            "Timeswap : Constant"
        );
        require(
            _tokenBalance.mul(_interestMax) >=
                uint256(_tokenReserve).mul(uint256(_interestReserve)),
            "Timeswap : Constant"
        );
        require(
            _insuranceDifference.mul(_interestDifference) >=
                uint256(__insuranceOut).mul(uint256(_interestOut)),
            "Timeswap : Constant"
        );

        // Update model
        _update(
            _tokenBalance,
            _insuranceBalance,
            _tokenReserve,
            _insuranceReserve,
            _interestReserve
        );

        // Emit event
        emit Lend(
            msg.sender,
            uint128(_tokenIn),
            _interestOut,
            __insuranceOut,
            _to
        );
    }

    function borrow(
        uint128 _tokenOut,
        uint128 _bondIn,
        uint128 _collateralInMin,
        uint128 _interestInMax,
        address _to,
        bytes calldata _data
    ) external nonReentrant() {
        // Initial require
        require(block.timestamp < maturity, "Timeswap : Bond Matured");
        require(_tokenOut > 0, "Timeswap : Insufficient Output");
        require(
            _interestInMax > 0,
            "Timeswap : Insufficient Output Max Amount"
        );
        require(
            _collateralInMin > 0,
            "Timeswao : Insufficient Output Min Amount"
        );

        // Get reserves
        (
            uint112 _tokenReserve,
            uint112 _insuranceReserve,
            uint112 _interestReserve,

        ) = viewReserves();
        require(_tokenOut < tokenReserve, "Timeswap : Insufficient Reserve");

        // Optimistically transfer tokens for flash feature
        require(_to != token, "Timesap : Invalid To");
        IERC20(token).safeTransfer(_to, _tokenOut); // optimistically transfer tokens
        if (_data.length > 0)
            TimeswapFlashInterface(_to).borrow(msg.sender, _tokenOut, _data); // call any arbitrary code for flash feature

        // Get token balance
        uint256 _tokenBalance = IERC20(token).balanceOf(address(this)).sub(
            uint256(totalPaid.debt)
        );
        uint256 _insuranceBalance = IERC20(collateral)
            .balanceOf(address(this))
            .add(uint256(totalPaid.collateral))
            .sub(uint256(totalDeposit.insurance));

        // Get collateral amount in
        uint256 _collateralIn = _insuranceBalance > _insuranceReserve
            ? _insuranceBalance.sub(uint256(_insuranceReserve))
            : 0;

        uint256 __tokenOut = _tokenReserve > _tokenBalance
            ? uint256(_tokenReserve).sub(_tokenBalance)
            : 0;

        // Mint token
        loanOf[_to].push(Loan(_bondIn, uint128(_collateralIn)));
        totalLoan = Loan(
            totalLoan.debt.add(_bondIn),
            totalLoan.collateral.add(uint128(_collateralIn))
        );

        // Get interest in
        uint128 _interestIn = _bondIn.sub(uint128(__tokenOut));
        uint128 __collateralInMin = _collateralInMin; // Avoid stacks too deep error
        require(
            _interestIn > 0 && _collateralIn > 0,
            "Timeswap : Insufficient Input"
        );
        require(
            _collateralIn >= _collateralInMin && _interestIn <= _interestInMax,
            "Timeswap : Outflow Max"
        );

        // Constant Product
        uint256 _insuranceMin = uint256(_insuranceReserve).add(
            uint256(_collateralInMin)
        );
        uint256 _interestMax = uint256(_interestReserve).add(
            uint256(_interestInMax)
        );
        require(
            _tokenBalance.mul(_insuranceMin) >=
                uint256(_tokenReserve).mul(uint256(_insuranceReserve)),
            "Timeswap : Constant"
        );
        require(
            _tokenBalance.mul(_interestMax) >=
                uint256(_tokenReserve).mul(uint256(_interestReserve)),
            "Timeswap : Constant"
        );
        require(
            _collateralIn.mul(uint256(_interestIn)) >=
                uint256(__collateralInMin).mul(uint256(_interestInMax)),
            "Timeswap : Constant"
        );

        // Update model
        _update(
            _tokenBalance,
            _insuranceBalance,
            _tokenReserve,
            _insuranceReserve,
            _interestReserve
        );

        // Emit event
        emit Borrow(
            msg.sender,
            uint128(__tokenOut),
            _interestIn,
            uint128(_collateralIn),
            _to
        );
    }

    function withdraw(
        uint128 _bondIn,
        uint128 _insuranceIn,
        uint128 _tokenOut,
        uint128 _collateralOut,
        address _to,
        bytes calldata _data
    ) external nonReentrant() {
        // Initial require
        require(block.timestamp >= maturity, "Timeswap : Bond Not Matured");
        require(
            _tokenOut > 0 || _collateralOut > 0,
            "Timeswap : Insufficient Output"
        );

        (, , uint112 _interestReserve, ) = viewReserves();

        // Get initial balance
        uint256 _tokenInitial = IERC20(token).balanceOf(address(this)).sub(
            uint256(_interestReserve)
        );
        uint256 _collateralInitial = IERC20(collateral).balanceOf(
            address(this)
        );

        uint128 _bondInitial = totalDeposit.bond.sub(totalWithdrawn.bond);
        uint128 _insuranceInitial = totalDeposit.insurance.sub(
            totalWithdrawn.insurance
        );

        // Optimistically transfer tokens for flash feature
        require(_to != token && _to != collateral, "Timesap : Invalid To");
        if (_tokenOut > 0) IERC20(token).safeTransfer(_to, _tokenOut); // optimistically transfer tokens
        if (_collateralOut > 0)
            IERC20(collateral).safeTransfer(_to, _collateralOut); // optimistically transfer tokens
        if (_data.length > 0)
            TimeswapFlashInterface(_to).withdraw(
                msg.sender,
                _tokenOut,
                _collateralOut,
                _data
            ); // call any arbitrary code for flash feature

        // Get balance
        uint256 _tokenBalance = IERC20(token).balanceOf(address(this)).sub(
            uint256(_interestReserve)
        );
        uint256 _collateralBalance = IERC20(collateral).balanceOf(
            address(this)
        );

        address __to = _to; // Avoid stacks too deep error
        uint128 __bondIn = _bondIn; // Avoid stacks too deep error
        uint128 __insuranceIn = _insuranceIn; // Avoid stacks too deep error

        // burn token
        totalWithdrawn = Deposit(
            totalWithdrawn.bond.add(__bondIn),
            totalWithdrawn.insurance.add(__insuranceIn)
        );
        depositOf[__to] = Deposit(
            depositOf[__to].bond.sub(__bondIn),
            depositOf[__to].insurance.sub(__insuranceIn)
        );

        uint256 __tokenOut = _tokenInitial >= _tokenBalance
            ? _tokenInitial.sub(_tokenBalance)
            : 0;
        uint256 __collateralOut = _collateralInitial >= _collateralBalance
            ? _collateralInitial.sub(_collateralBalance)
            : 0;

        // Get balance
        uint128 _bondBalance = totalDeposit.bond.sub(totalWithdrawn.bond);
        uint128 _insuranceBalance = totalDeposit.insurance.sub(
            totalWithdrawn.insurance
        );

        require(
            _tokenBalance.mul(uint256(_bondInitial)) >=
                uint256(_bondBalance).mul(_tokenInitial),
            "Timeswap : Deposit Rule"
        );
        require(
            _collateralBalance.mul(uint256(_insuranceInitial)) >=
                uint256(_insuranceBalance).mul(_collateralInitial),
            "Timeswap : Deposit Rule"
        );

        // Emit event
        emit Withdraw(
            msg.sender,
            uint128(__tokenOut),
            uint128(__collateralOut),
            __bondIn,
            __insuranceIn,
            __to
        );
    }

    function pay(
        uint128 _collateralOut,
        uint256 _index,
        address _to,
        bytes calldata _data
    ) external nonReentrant() {
        // Initial require
        require(block.timestamp < maturity, "Timeswap : Bond Matured");

        // Get reserves
        (uint112 _tokenReserve, uint112 _insuranceReserve, , ) = viewReserves();

        // Optimistically transfer tokens for flash feature
        require(_to != collateral, "Timeswap : Invalid To");
        IERC20(collateral).safeTransfer(_to, _collateralOut); // optimistically transfer tokens
        if (_data.length > 0)
            TimeswapFlashInterface(_to).pay(msg.sender, _collateralOut, _data); // call any arbitrary code for flash feature

        // Get balance
        uint256 _tokenBalance = IERC20(token).balanceOf(address(this)).sub(
            uint256(totalPaid.debt)
        );
        uint256 _insuranceBalance = IERC20(collateral)
            .balanceOf(address(this))
            .add(uint256(totalPaid.collateral))
            .sub(uint256(totalDeposit.insurance));

        uint256 _tokenIn = _tokenBalance > _tokenReserve
            ? _tokenBalance.sub(uint256(_tokenReserve))
            : 0;
        uint256 __collateralOut = _insuranceReserve > _insuranceBalance
            ? uint256(_insuranceReserve).sub(_insuranceBalance)
            : 0;

        address __to = _to;
        uint256 __index = _index;

        uint128 _debt = loanOf[_to][_index].debt;
        uint128 _collateral = loanOf[_to][_index].collateral;

        loanOf[__to][__index] = Loan(
            _debt.sub(uint128(_tokenIn)),
            _collateral.sub(uint128(__collateralOut))
        );
        totalPaid = Loan(
            totalPaid.debt.add(uint128(_tokenIn)),
            totalPaid.collateral.add(uint128(__collateralOut))
        );

        require(
            uint256(loanOf[__to][__index].debt).mul(uint256(_collateral)) >=
                uint256(loanOf[__to][__index].collateral).mul(uint256(_debt)),
            "Timeswap : Loan Rule"
        );

        // Emit event
        emit Pay(
            msg.sender,
            uint128(_tokenIn),
            uint128(__collateralOut),
            __index,
            __to
        );
    }

    // force balances to match reserves
    function skim(address _to) external nonReentrant() {
        // address _token = token; // gas savings ???
        // address _collateral = collateral; // gas savings ???
        (uint112 _tokenReserve, uint112 _insuranceReserve, , ) = viewReserves();
        (uint256 _tokenBalance, uint256 _insuranceBalance) = viewBalance();
        if (_tokenBalance > uint256(_tokenReserve))
            IERC20(token).safeTransfer(
                _to,
                _tokenBalance.sub(uint256(_tokenReserve))
            );
        if (_tokenBalance > uint256(_insuranceReserve))
            IERC20(collateral).safeTransfer(
                _to,
                _insuranceBalance.sub(uint256(_insuranceReserve))
            );
    }

    // force reserves to match balances
    function sync() external nonReentrant() {
        (
            uint112 _tokenReserve,
            uint112 _insuranceReserve,
            uint112 _interestReserve,

        ) = viewReserves();
        (uint256 _tokenBalance, uint256 _insuranceBalance) = viewBalance();
        _update(
            _tokenBalance,
            _insuranceBalance,
            _tokenReserve,
            _insuranceReserve,
            _interestReserve
        );
    }

    // HELPER

    function _update(
        uint256 _tokenBalance,
        uint256 _insuranceBalance,
        uint112 _tokenReserve,
        uint112 _insuranceReserve,
        uint112 _interestReserve
    ) private {
        require(
            _tokenBalance <= uint112(-1) && _insuranceBalance <= uint112(-1),
            "Timeswap : Overflow"
        );
        uint32 _blockTimestamp = uint32(block.timestamp % (2**32));
        uint32 _timeElapsed = _blockTimestamp - blockTimestampLast;
        if (
            _timeElapsed > 0 &&
            _tokenReserve != 0 &&
            _insuranceReserve != 0 &&
            _interestReserve != 0
        ) {
            // * never overflows, and + overflow is desired
            insurancePriceCumulativeLast +=
                uint256(
                    UQ112x112.encode(_insuranceReserve).uqdiv(_tokenReserve)
                ) *
                _timeElapsed;
            interestPriceCumulativeLast +=
                uint256(
                    UQ112x112.encode(_interestReserve).uqdiv(_tokenReserve)
                ) *
                _timeElapsed;
        }
        tokenReserve = uint112(_tokenBalance);
        insuranceReserve = uint112(_insuranceBalance);
        blockTimestampLast = _blockTimestamp;
        emit Sync(tokenReserve, insuranceReserve);
    }
}
