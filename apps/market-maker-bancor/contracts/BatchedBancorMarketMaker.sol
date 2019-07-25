/*
 * SPDX-License-Identitifer:    GPL-3.0-or-later
 */

pragma solidity 0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/common/EtherTokenConstant.sol";
import "@aragon/os/contracts/common/IsContract.sol";
import "@aragon/os/contracts/common/SafeERC20.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "@aragon/os/contracts/lib/token/ERC20.sol";

import "@aragon/apps-token-manager/contracts/TokenManager.sol";
import "@aragon/apps-vault/contracts/Vault.sol";

import "@ablack/fundraising-interface-core/contracts/IMarketMakerController.sol";
import "@ablack/fundraising-formula-bancor/contracts/BancorFormula.sol";


contract BatchedBancorMarketMaker is EtherTokenConstant, IsContract, AragonApp {
    using SafeERC20 for ERC20;
    using SafeMath for uint256;

    bytes32 public constant ADD_COLLATERAL_TOKEN_ROLE = keccak256("ADD_COLLATERAL_TOKEN_ROLE");
    bytes32 public constant UPDATE_COLLATERAL_TOKEN_ROLE = keccak256("UPDATE_COLLATERAL_TOKEN_ROLE");
    bytes32 public constant UPDATE_BENEFICIARY_ROLE = keccak256("UPDATE_BENEFICIARY_ROLE");
    bytes32 public constant UPDATE_FORMULA_ROLE = keccak256("UPDATE_FORMULA_ROLE");
    bytes32 public constant UPDATE_FEES_ROLE = keccak256("UPDATE_FEES_ROLE");
    bytes32 public constant OPEN_BUY_ORDER_ROLE = keccak256("OPEN_BUY_ORDER_ROLE");
    bytes32 public constant OPEN_SELL_ORDER_ROLE = keccak256("OPEN_SELL_ORDER_ROLE");

    uint64 public constant PCT_BASE = 10 ** 18; // 0% = 0; 1% = 10^16; 100% = 10^18
    uint32 public constant PPM = 1000000;

    string private constant ERROR_CONTROLLER_NOT_CONTRACT = "BMM_CONTROLLER_NOT_CONTRACT";
    string private constant ERROR_TM_NOT_CONTRACT = "BMM_TM_NOT_CONTRACT";
    string private constant ERROR_RESERVE_NOT_CONTRACT = "BMM_RESERVE_NOT_CONTRACT";
    string private constant ERROR_FORMULA_NOT_CONTRACT = "BMM_FORMULA_NOT_CONTRACT";
    string private constant ERROR_NOT_CONTRACT = "BMM_NOT_CONTRACT";
    string private constant ERROR_BATCH_BLOCKS_ZERO = "BMM_BATCH_BLOCKS_ZERO";
    string private constant ERROR_FEE_PERCENTAGE_TOO_HIGH = "BMM_FEE_PERCENTAGE_TOO_HIGH";
    string private constant ERROR_COLLATERAL_NOT_ETH_OR_CONTRACT = "BMM_COLLATERAL_NOT_ETH_OR_ERC20";
    string private constant ERROR_COLLATERAL_ALREADY_WHITELISTED = "BMM_COLLATERAL_ALREADY_WHITELISTED";
    string private constant ERROR_COLLATERAL_NOT_WHITELISTED = "BMM_COLLATERAL_NOT_WHITELISTED";
    string private constant ERROR_SLIPPAGE_EXCEEDS_LIMIT = "BMM_SLIPPAGE_EXCEEDS_LIMIT";
    string private constant ERROR_BUY_VALUE_ZERO = "BMM_BUY_VALUE_ZERO";
    string private constant ERROR_SELL_AMOUNT_ZERO = "BMM_SELL_AMOUNT_ZERO";
    string private constant ERROR_INSUFFICIENT_COLLATERAL_VALUE = "BMM_INSUFFICIENT_COLLATERAL_VALUE";
    string private constant ERROR_INSUFFICIENT_BALANCE = "BMM_INSUFFICIENT_BALANCE";
    string private constant ERROR_INSUFFICIENT_POOL_BALANCE = "BMM_INSUFFICIENT_POOL_BALANCE";
    string private constant ERROR_NOTHING_TO_CLAIM = "BMM_NOTHING_TO_CLAIM";
    string private constant ERROR_BATCHES_ALREADY_CLEARED = "BMM_BATCHES_ALREADY_CLEARED";
    string private constant ERROR_BATCH_NOT_CLEARED = "BMM_BATCH_NOT_CLEARED";
    string private constant ERROR_BATCH_NOT_OVER = "BMM_BATCH_NOT_OVER";
    string private constant ERROR_TRANSFER_FROM_FAILED = "BMM_TRANSFER_FROM_FAILED";

    struct Collateral {
        bool    whitelisted;
        uint256 virtualSupply;
        uint256 virtualBalance;
        uint32  reserveRatio;
    }

    struct MetaBatch {
        bool    initialized;
        uint256 realSupply;
        mapping(address => Batch) batches;
    }

    struct Batch {
        bool    initialized;
        uint256 supply;
        uint256 balance;
        uint32  reserveRatio;
        uint256 totalBuySpend;
        uint256 totalBuyReturn;
        uint256 totalSellSpend;
        uint256 totalSellReturn;
        mapping(address => uint256) buyers;
        mapping(address => uint256) sellers;
    }

    IMarketMakerController public controller;
    TokenManager           public tokenManager;
    ERC20                  public token;
    Vault                  public reserve;
    address                public beneficiary;
    IBancorFormula         public formula;

    uint256 public batchBlocks;
    uint256 public maximumSlippage;
    uint256 public buyFeePct;
    uint256 public sellFeePct;
    uint256 public tokensToBeMinted;
    mapping(address => uint256)    public collateralsToBeClaimed;
    mapping(address => Collateral) public collaterals;
    mapping(uint256 => MetaBatch)  public metaBatches;

    event AddCollateralToken(address indexed collateral, uint256 virtualSupply, uint256 virtualBalance, uint32 reserveRatio);
    event RemoveCollateralToken(address indexed collateral);
    event UpdateCollateralToken(address indexed collateral, uint256 virtualSupply, uint256 virtualBalance, uint32 reserveRatio);
    event UpdateBeneficiary(address indexed beneficiary);
    event UpdateFormula(address indexed formula);
    event UpdateFees(uint256 buyFee, uint256 sellFee);
    event NewMetaBatch(uint256 indexed id, uint256 supply);
    event NewBatch(uint256 indexed id, address indexed collateral, uint256 supply, uint256 balance, uint32 reserveRatio);
    event NewBuyOrder(address indexed buyer, uint256 indexed batchId, address indexed collateral, uint256 fee, uint256 value);
    event NewSellOrder(address indexed seller, uint256 indexed batchId, address indexed collateral, uint256 amount);
    event ReturnBuyOrder(address indexed buyer, uint256 indexed batchId, address indexed collateral, uint256 amount);
    event ReturnSellOrder(address indexed seller, uint256 indexed batchId, address indexed collateral, uint256 fee, uint256 value);
    event UpdatePricing(uint256 indexed _batchId, address indexed _collateral, uint256 totalBuySpend, uint256 totalBuyReturn, uint256 totalSellSpend, uint256 totalSellReturn);

    function initialize(
        IMarketMakerController _controller,
        TokenManager           _tokenManager,
        Vault                  _reserve,
        address                _beneficiary,
        IBancorFormula         _formula,
        uint256                _batchBlocks,
        uint256                _buyFee,
        uint256                _sellFee,
        uint256                _maximumSlippage
    )
        external onlyInit
    {
        initialized();

        require(isContract(_controller), ERROR_CONTROLLER_NOT_CONTRACT);
        require(isContract(_tokenManager), ERROR_TM_NOT_CONTRACT);
        require(isContract(_reserve), ERROR_RESERVE_NOT_CONTRACT);
        require(isContract(_formula), ERROR_FORMULA_NOT_CONTRACT);
        require(_batchBlocks > 0, ERROR_BATCH_BLOCKS_ZERO);
        require(_buyFee < PCT_BASE, ERROR_FEE_PERCENTAGE_TOO_HIGH);
        require(_sellFee < PCT_BASE, ERROR_FEE_PERCENTAGE_TOO_HIGH);

        controller = _controller;
        tokenManager = _tokenManager;
        token = ERC20(tokenManager.token());
        reserve = _reserve;
        beneficiary = _beneficiary;
        formula = _formula;
        batchBlocks = _batchBlocks;
        buyFeePct = _buyFee;
        sellFeePct = _sellFee;
        maximumSlippage = _maximumSlippage;
    }

    /***** external functions *****/

    /**
      * @notice Add `_collateral.symbol(): string` as a whitelisted collateral token
      * @param _collateral The address of the collateral token to be whitelisted
      * @param _virtualSupply The virtual supply to be used for that collateral token
      * @param _virtualBalance The virtual balance to be used for that collateral token
      * @param _reserveRatio The reserve ratio to be used for that collateral token [in PPM]
    */
    function addCollateralToken(address _collateral, uint256 _virtualSupply, uint256 _virtualBalance, uint32 _reserveRatio)
        external auth(ADD_COLLATERAL_TOKEN_ROLE)
    {
        require(isContract(_collateral) || _collateral == ETH, ERROR_COLLATERAL_NOT_ETH_OR_CONTRACT);
        require(!_collateralIsWhitelisted(_collateral), ERROR_COLLATERAL_ALREADY_WHITELISTED);

        _addCollateralToken(_collateral, _virtualSupply, _virtualBalance, _reserveRatio);
    }

    /**
     * @notice Update `_collateral.symbol(): string` collateralization settings
     * @param _collateral The address of the collateral token whose collateralization settings are to be updated
     * @param _virtualSupply The new virtual supply to be used for that collateral token
     * @param _virtualBalance The new virtual balance to be used for that collateral token
     * @param _reserveRatio The new reserve ratio to be used for that collateral token [in PPM]
    */
    function updateCollateralToken(address _collateral, uint256 _virtualSupply, uint256 _virtualBalance, uint32 _reserveRatio)
        external auth(UPDATE_COLLATERAL_TOKEN_ROLE)
    {
        require(_collateralIsWhitelisted(_collateral), ERROR_COLLATERAL_NOT_WHITELISTED);

        _updateCollateralToken(_collateral, _virtualSupply, _virtualBalance, _reserveRatio);
    }

    /**
     * @notice Update the beneficiary to `_beneficiary`
     * @param _beneficiary The new beneficiary to be used
    */
    function updateBeneficiary(address _beneficiary) external auth(UPDATE_BENEFICIARY_ROLE) {
        _updateBeneficiary(_beneficiary);
    }

    /**
     * @notice Update the address of the BancorFormula contract to `_formula`
     * @param _formula The address of the new BancorFormula contract to be used
    */
    function updateFormula(IBancorFormula _formula) external auth(UPDATE_FORMULA_ROLE) {
        require(isContract(_formula), ERROR_FORMULA_NOT_CONTRACT);

        _updateFormula(_formula);
    }

    /**
     * @notice Update the fee percentage deducted from all buy and sell orders to respectively `@formatPct(_buyFee)` % and `@formatPct(_sellFee)` %
     * @param _buyFee The new buy fee to be used
     * @param _sellFee The new sell fee to be used
    */
    function updateFees(uint256 _buyFee, uint256 _sellFee) external auth(UPDATE_FEES_ROLE) {
        require(_buyFee < PCT_BASE, ERROR_FEE_PERCENTAGE_TOO_HIGH);
        require(_sellFee < PCT_BASE, ERROR_FEE_PERCENTAGE_TOO_HIGH);

        _updateFees(_buyFee, _sellFee);
    }

    /**
     * @notice Open a buy order worth `@tokenAmount(_collateral, _value)`
     * @param _buyer The address of the buyer
     * @param _collateral The address of the collateral token to be spent
     * @param _value The amount of collateral token to be spent
    */
    function openBuyOrder(address _buyer, address _collateral, uint256 _value) external payable auth(OPEN_BUY_ORDER_ROLE) {
        require(_value > 0, ERROR_BUY_VALUE_ZERO);
        require(_collateralIsWhitelisted(_collateral), ERROR_COLLATERAL_NOT_WHITELISTED);
        require(_collateralValueIsSufficient(_buyer, _collateral, _value, msg.value), ERROR_INSUFFICIENT_COLLATERAL_VALUE);

        _openBuyOrder(_buyer, _collateral, _value);
    }

    /**
     * @notice Open a sell order worth `@tokenAmount(self.token(), _amount)`
     * @param _seller The address of the seller
     * @param _collateral The address of the collateral token to be returned
     * @param _amount The amount of bonded token to be spent
    */
    function openSellOrder(address _seller, address _collateral, uint256 _amount) external auth(OPEN_SELL_ORDER_ROLE) {
        require(_amount != 0, ERROR_SELL_AMOUNT_ZERO);
        require(_collateralIsWhitelisted(_collateral), ERROR_COLLATERAL_NOT_WHITELISTED);
        require(_bondBalanceIsSufficient(_seller, _amount), ERROR_INSUFFICIENT_BALANCE);

        _openSellOrder(_seller, _collateral, _amount);
    }

    /**
     * @notice Return the results of `_buyer`'s `_collateral.symbol(): string` buy orders from batch #`_batchId`
     * @param _buyer The address of the user whose buy orders are to be returned
     * @param _collateral The address of the collateral token used
     * @param _batchId The id of the batch used
    */
    function claimBuyOrder(address _buyer, uint256 _batchId, address _collateral) external nonReentrant isInitialized {
        require(_collateralIsWhitelisted(_collateral), ERROR_COLLATERAL_NOT_WHITELISTED);
        require(_batchIsOver(_batchId), ERROR_BATCH_NOT_OVER);

        Batch storage batch = metaBatches[_batchId].batches[_collateral];
        require(batch.buyers[_buyer] != 0, ERROR_NOTHING_TO_CLAIM);

        _claimBuyOrder(_buyer, _batchId, _collateral);
    }

    /**
     * @notice Return the results of `_seller`'s `_collateral.symbol(): string` sell orders from batch #`_batchId`
     * @param _seller The address of the user whose sell orders are to be returned
     * @param _collateral The address of the collateral token used
     * @param _batchId The id of the batch used
    */
    function claimSellOrder(address _seller, uint256 _batchId, address _collateral) external nonReentrant isInitialized {
        require(_collateralIsWhitelisted(_collateral), ERROR_COLLATERAL_NOT_WHITELISTED);
        require(_batchIsOver(_batchId), ERROR_BATCH_NOT_OVER);

        Batch storage batch = metaBatches[_batchId].batches[_collateral];
        require(batch.sellers[_seller] != 0, ERROR_NOTHING_TO_CLAIM);

        _claimSellOrder(_seller, _batchId, _collateral);
    }

    /***** public view functions *****/

    function getCurrentBatchId() public view isInitialized returns (uint256) {
        return _currentBatchId();
    }

    function getBatch(uint256 _batchId, address _collateral)
        public view isInitialized
        returns (bool, uint256, uint256, uint32, uint256, uint256, uint256, uint256)
    {
        Batch storage batch = metaBatches[_batchId].batches[_collateral];

        return (
            batch.initialized,
            batch.supply,
            batch.balance,
            batch.reserveRatio,
            batch.totalBuySpend,
            batch.totalBuyReturn,
            batch.totalSellSpend,
            batch.totalSellReturn
        );
    }

    function getCollateralToken(address _collateral) public view isInitialized returns (bool, uint256, uint256, uint32) {
        Collateral storage collateral = collaterals[_collateral];

        return (collateral.whitelisted, collateral.virtualSupply, collateral.virtualBalance, collateral.reserveRatio);
    }

    /***** internal functions *****/

    function _staticPrice(uint256 _supply, uint256 _balance, uint32 _reserveRatio) internal view returns (uint256) {
        return uint256(PPM).mul(_balance).div(_supply.mul(uint256(_reserveRatio)));
    }

    function _currentBatchId() internal view returns (uint256) {
        return (block.number.div(batchBlocks)).mul(batchBlocks);
    }

    function _currentBatch(address _collateral) internal returns (uint256, Batch storage) {
        uint256 batchId = _currentBatchId();
        MetaBatch storage metaBatch = metaBatches[batchId];
        Batch storage batch = metaBatch.batches[_collateral];

        if (!metaBatch.initialized) {
            /**
             * NOTE: all collateral batches should be initialized with the same supply to
             * avoid price manipulation between different collaterals in the same meta-batch
             * NOTE: we don't need to do the same with collateral balances as orders in one collateral can't affect
             * the pool's balance in another collateral and tap is a step-function of the meta-batch duration
            */

            /*
             * NOTE: realSupply(metaBatch) = totalSupply(metaBatchInitialization) + tokensToBeMinted(metaBatchInitialization)
             * 1. buy and sell orders incoming during the current meta-batch and affecting totalSupply or tokensToBeMinted
             * should not be taken into account in the price computation [they are already a part of the batched pricing computation]
             * 2. the only way for totalSupply to be modified during a meta-batch [outside of incoming buy and sell orders]
             * is for buy orders from previous meta-batches to be claimed [and tokens to be minted]:
             * as such totalSupply(metaBatch) + tokenToBeMinted(metaBatch) will always equal totalSupply(metaBatchInitialization) + tokenToBeMinted(metaBatchInitialization)
            */


            metaBatch.realSupply = token.totalSupply().add(tokensToBeMinted);
            metaBatch.initialized = true;

            emit NewMetaBatch(batchId, metaBatch.realSupply);
        }

        if (!batch.initialized) {
            /**
             * NOTE: supply(batch) = realSupply(metaBatch) + virtualSupply(batchInitialization)
             * virtualSupply can technically be updated during a batch: the on-going batch will still use
             * its value at the time of initialization [it's up to the updater to act wisely]
            */
            /**
             * NOTE: balance(batch) = poolBalance(batchInitialization) - collateralsToBeClaimed(batchInitialization) + virtualBalance(metaBatchInitialization)
             * 1. buy and sell orders incoming during the current batch and affecting poolBalance or collateralsToBeClaimed
             * should not be taken into account in the price computation [they are already a part of the batched price computation]
             * 2. the only way for poolBalance to be modified during a batch [outside of incoming buy and sell orders]
             * is for sell orders from previous meta-batches to be claimed [and collateral to be transfered] as the tap is a step-function of the meta-batch duration:
             * as such poolBalance(batch) - collateralToBeClaimed(batch) will always equal poolBalance(batchInitialization) - collateralsToBeClaimed(batchInitialization)
             * 3. virtualBalance can technically be updated during a batch: the on-going batch will still use
             * its value at the time of initialization [it's up to the updater to act wisely]
            */

            batch.supply = metaBatch.realSupply.add(collaterals[_collateral].virtualSupply);
            batch.balance = controller.balanceOf(address(reserve), _collateral).sub(collateralsToBeClaimed[_collateral]).add(collaterals[_collateral].virtualBalance);
            batch.reserveRatio = collaterals[_collateral].reserveRatio;
            batch.initialized = true;

            emit NewBatch(batchId, _collateral, batch.supply, batch.balance, batch.reserveRatio);
        }

        return (batchId, batch);
    }

    /* internal check functions */

    function _batchIsOver(uint256 _batchId) internal view returns (bool) {
        return _batchId < _currentBatchId();
    }

    function _collateralIsWhitelisted(address _collateral) internal view returns (bool) {
        return collaterals[_collateral].whitelisted;
    }

    function _collateralValueIsSufficient(address _buyer, address _collateral, uint256 _value, uint256 _msgValue) internal view returns (bool) {
        if (_collateral == ETH) {
            return _msgValue >= _value;
        } else {
            return controller.balanceOf(_buyer, _collateral) >= _value;
        }
    }

    function _bondBalanceIsSufficient(address _seller, uint256 _amount) internal view returns (bool) {
        return tokenManager.spendableBalanceOf(_seller) >= _amount;
    }

    function _poolBalanceIsSufficient(address _collateral) internal view returns (bool) {
        return controller.balanceOf(address(reserve), _collateral) >= collateralsToBeClaimed[_collateral];
    }

    function _slippageIsValid(Batch storage _batch) internal view returns (bool) {
        uint256 staticPrice = _staticPrice(_batch.supply, _batch.balance, _batch.reserveRatio);

        // if static price is zero let's consider that every slippage is valid
        if (staticPrice == 0) {
            return true;
        }

        return _buySlippageIsValid(_batch, staticPrice) && _sellSlippageIsValid(_batch, staticPrice);
    }

    function _buySlippageIsValid(Batch storage _batch, uint256 _startingPrice) internal view returns (bool) {
        // the case where starting price is zero is handled
        // by the meta function _slippageIsValid()

        // if there are no buy orders price can't go up and buyers don't care
        if (_batch.totalBuySpend == 0)
            return true;

        // if there are buy orders but no token to mint
        // [cause price is too high or order too small]
        // the order should be discarded
        if (_batch.totalBuyReturn == 0) {
            return false;
        }

        uint256 buyPrice = _batch.totalBuySpend.div(_batch.totalBuyReturn);

        // if buyPrice is lower than _startingPrice buyers don't care
        if (buyPrice <= _startingPrice) {
            return true;
        }

        uint256 slippage = (buyPrice.sub(_startingPrice)).mul(PCT_BASE).div(_startingPrice);

        if (slippage > maximumSlippage) {
            return false;
        }

        return true;
    }

    function _sellSlippageIsValid(Batch storage _batch, uint256 _startingPrice) internal view returns (bool) {
        // the case where starting price is zero is handled
        // by the meta function _slippageIsValid()

        // if there are no sell orders price can't go down and sellers don't care
        if (_batch.totalSellSpend == 0)
            return true;

        // if there are sell orders but no collateral to transfer back
        // [cause price is too low or order too small] the order should be discarded
        if (_batch.totalSellReturn == 0) {
            return false;
        }

        uint256 sellPrice = _batch.totalSellReturn.div(_batch.totalSellSpend);

        // if sellPrice is higher than _startingPrice sellers don't care
        if (sellPrice >= _startingPrice) {
            return true;
        }

        uint256 slippage = (_startingPrice.sub(sellPrice)).mul(PCT_BASE).div(_startingPrice);

        if (slippage > maximumSlippage) {
            return false;
        }

        return true;
    }

    /* internal business logic functions */

    function _addCollateralToken(address _collateral, uint256 _virtualSupply, uint256 _virtualBalance, uint32 _reserveRatio) internal {
        collaterals[_collateral].whitelisted = true;
        collaterals[_collateral].virtualSupply = _virtualSupply;
        collaterals[_collateral].virtualBalance = _virtualBalance;
        collaterals[_collateral].reserveRatio = _reserveRatio;

        emit AddCollateralToken(_collateral, _virtualSupply, _virtualBalance, _reserveRatio);
    }

    function _updateCollateralToken(address _collateral, uint256 _virtualSupply, uint256 _virtualBalance, uint32 _reserveRatio) internal {
        collaterals[_collateral].virtualSupply = _virtualSupply;
        collaterals[_collateral].virtualBalance = _virtualBalance;
        collaterals[_collateral].reserveRatio = _reserveRatio;

        emit UpdateCollateralToken(_collateral, _virtualSupply, _virtualBalance, _reserveRatio);
    }

    function _updateBeneficiary(address _beneficiary) internal {
        beneficiary = _beneficiary;

        emit UpdateBeneficiary(_beneficiary);
    }

    function _updateFormula(IBancorFormula _formula) internal {
        formula = _formula;

        emit UpdateFormula(address(_formula));
    }

    function _updateFees(uint256 _buyFee, uint256 _sellFee) internal {
        buyFeePct = _buyFee;
        sellFeePct = _sellFee;

        emit UpdateFees(_buyFee, _sellFee);
    }

    function _openBuyOrder(address _buyer, address _collateral, uint256 _value) internal {
        (uint256 batchId, Batch storage batch) = _currentBatch(_collateral);

        // deduct fee
        uint256 fee = _value.mul(buyFeePct).div(PCT_BASE);
        uint256 value = _value.sub(fee);

        // collect fee and collateral
        if (fee > 0) {
            _transfer(_buyer, beneficiary, _collateral, fee);
        }
        _transfer(_buyer, address(reserve), _collateral, value);

        // update batch
        uint256 deprecatedBuyReturn = batch.totalBuyReturn;
        batch.totalBuySpend = batch.totalBuySpend.add(value);
        batch.buyers[_buyer] = batch.buyers[_buyer].add(value);

        // update pricing
        _updatePricing(batch, batchId, _collateral);

        // update the amount of tokens to be minted
        tokensToBeMinted = tokensToBeMinted.sub(deprecatedBuyReturn).add(batch.totalBuyReturn);

        // sanity checks
        require(_slippageIsValid(batch), ERROR_SLIPPAGE_EXCEEDS_LIMIT);

        emit NewBuyOrder(_buyer, batchId, _collateral, fee, value);
    }

    function _openSellOrder(address _seller, address _collateral, uint256 _amount) internal {
        (uint256 batchId, Batch storage batch) = _currentBatch(_collateral);

        // burn bonds
        tokenManager.burn(_seller, _amount);

        // update batch
        uint256 deprecatedSellReturn = batch.totalSellReturn;
        batch.totalSellSpend = batch.totalSellSpend.add(_amount);
        batch.sellers[_seller] = batch.sellers[_seller].add(_amount);

        // update pricing
        _updatePricing(batch, batchId, _collateral);

        // update the amount of tokens collaterals to be claimed
        collateralsToBeClaimed[_collateral] = collateralsToBeClaimed[_collateral].sub(deprecatedSellReturn).add(batch.totalSellReturn);

        // sanity checks
        require(_slippageIsValid(batch), ERROR_SLIPPAGE_EXCEEDS_LIMIT);
        require(_poolBalanceIsSufficient(_collateral), ERROR_INSUFFICIENT_POOL_BALANCE);


        emit NewSellOrder(_seller, batchId, _collateral, _amount);
    }

    function _claimBuyOrder(address _buyer, uint256 _batchId, address _collateral) internal {
        Batch storage batch = metaBatches[_batchId].batches[_collateral];
        uint256 buyReturn = (batch.buyers[_buyer].mul(batch.totalBuyReturn)).div(batch.totalBuySpend);

        batch.buyers[_buyer] = 0;

        if (buyReturn > 0) {
            tokensToBeMinted = tokensToBeMinted.sub(buyReturn);
            tokenManager.mint(_buyer, buyReturn);
        }

        emit ReturnBuyOrder(_buyer, _batchId, _collateral, buyReturn);
    }

    function _claimSellOrder(address _seller, uint256 _batchId, address _collateralToken) internal {
        // Batch storage batch = collaterals[_collateralToken].batches[_batchId];
        // uint256 sellReturn = (batch.sellers[_seller].mul(batch.totalSellReturn)).div(batch.totalSellSpend);
        // uint256 fee = sellReturn.mul(sellFeePct).div(PCT_BASE);
        // uint256 amountAfterFee = sellReturn.sub(fee);

        // batch.sellers[_seller] = 0;

        // if (amountAfterFee > 0) {
        //     reserve.transfer(_collateralToken, _seller, amountAfterFee);
        //     // also update collateralsToBeClaimed;
        // }
        // if (fee > 0) {
        //     reserve.transfer(_collateralToken, beneficiary, fee);
        // }


        // emit ReturnSellOrder(_seller, _batchId, _collateral, fee, amountAfterFee);
    }

    function _updatePricing(Batch storage batch, uint256 _batchId, address _collateral) internal {
        // if there are no orders do nothing
        if (batch.totalSellSpend == 0 && batch.totalBuySpend == 0)
            return;

        // static price is the current exact price in collateral
        // per token according to the initial state of the batch
        uint256 staticPrice = _staticPrice(batch.supply, batch.balance, batch.reserveRatio);

        // if staticPrice is zero then resultOfSell [= 0] <= batch.totalBuySpend
        // so totalSellReturn will be zero and totalBuyReturn will be
        // computed normally along the formula

        // 1. we want to find out if there are more buy orders or more sell orders
        // 2. to do this we check the result of all sell and buy orders at the current
        // exact price: if the result of sells is larger than the pending buys,
        // there are more sells than buys [and vice-versa]
        uint256 resultOfSell = batch.totalSellSpend.mul(staticPrice);

        if (resultOfSell > batch.totalBuySpend) {
            // >> there are more sells than buys

            // 1. first we execute all pending buy orders at the current exact
            // price because there is at least one sell order for each buy order
            // 2. then the final sell return is the addition of this first
            // matched return and the remaining bonding curve return

            // the number of tokens bought as a result of all buy orders combined at the
            // current exact price [which is less than the total amount of tokens to be sold]
            batch.totalBuyReturn = batch.totalBuySpend.div(staticPrice);
            // the number of tokens left over to be sold along the curve which is the difference
            // between the original total sell order and the result of all the buy orders
            uint256 remainingSell = batch.totalSellSpend.sub(batch.totalBuyReturn);
            // the amount of collateral generated by selling tokens left over to be sold
            // along the bonding curve in the batch initial state [as if the buy orders
            // never existed and the sell order was just smaller than originally thought]
            uint256 remainingSellReturn = formula.calculateSaleReturn(batch.supply, batch.balance, batch.reserveRatio, remainingSell);
            // the total result of all sells is the original amount of buys which were matched
            // plus the remaining sells which were executed along the bonding curve
            batch.totalSellReturn = batch.totalBuySpend.add(remainingSellReturn);
        } else {
            // >> there are more buys than sells

            // 1. first we execute all pending sell orders at the current exact
            // price because there is at least one buy order for each sell order
            // 2. then the final buy return is the addition of this first
            // matched return and the remaining bonding curve return

            // the number of collaterals bought as a result of all sell orders combined at the
            // current exact price [which is less than the total amount of collateral to be spent]
            batch.totalSellReturn = resultOfSell;
            // the number of collaterals left over to be spent along the curve which is the difference
            // between the original total buy order and the result of all the sell orders
            uint256 remainingBuy = batch.totalBuySpend.sub(resultOfSell);
            // the amount of tokens generated by selling collaterals left over to be spent
            // along the bonding curve in the batch initial state [as if the sell orders
            // never existed and the buy order was just smaller than originally thought]
            uint256 remainingBuyReturn = formula.calculatePurchaseReturn(batch.supply, batch.balance, batch.reserveRatio, remainingBuy);
            // the total result of all buys is the original amount of buys which were matched
            // plus the remaining buys which were executed along the bonding curve
            batch.totalBuyReturn = batch.totalSellSpend.add(remainingBuyReturn);
        }


        emit UpdatePricing(_batchId, _collateral, batch.totalBuySpend, batch.totalBuyReturn, batch.totalSellSpend, batch.totalSellReturn);
    }

    function _transfer(address _from, address _to, address _collateralToken, uint256 _amount) internal {
        if (_collateralToken == ETH) {
            _to.transfer(_amount);
        } else {
            require(ERC20(_collateralToken).safeTransferFrom(_from, _to, _amount), ERROR_TRANSFER_FROM_FAILED);
        }
    }
}
