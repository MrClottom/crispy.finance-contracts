// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Market is Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public constant SCALE = 1e18;

    enum OrderStatus {
        BUY,
        SELL,
        FILLED,
        CANCELLED
    }

    struct Order {
        OrderStatus status;
        address creator;
        address permittedFiller;
        IERC721 tokenContract;
        uint256 tokenId;
        IERC20 paymentToken;
        uint256 paymentAmount;
        uint256 allowedInverseFee;
    }

    uint256 public iFee; // inverse fee; 1 - fee
    Order[] public orderBook;

    event FeeSet(uint256 indexed newInverseFee);
    event OrderCreated(
        uint256 indexed orderId,
        address indexed creator,
        address indexed permittedFiller
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed filler,
        uint256 usedInverseFee
    );
    event OrderCancelled(uint256 indexed orderId);

    constructor() Ownable() { }

    function setFee(uint256 _newInverseFee) external onlyOwner {
        iFee = _newInverseFee;
        emit FeeSet(_newInverseFee);
    }

    function collectFees(
        IERC20 _paymentToken,
        address _destination,
        uint256 _withdrawAmount
    ) external onlyOwner {
        _paymentToken.safeTransfer(_destination, _withdrawAmount);
    }

    function createOrder(
        bool _isSellOrder,
        address _permittedFiller,
        IERC721 _tokenContract,
        uint256 _tokenId,
        IERC20 _paymentToken,
        uint256 _paymentAmount,
        uint256 _allowedInverseFee
    ) external returns (uint256 orderId) {
        OrderStatus status = _isSellOrder ? OrderStatus.SELL : OrderStatus.BUY;
        orderId = orderBook.length;
        orderBook.push(Order({
            status: status,
            creator: msg.sender,
            permittedFiller: _permittedFiller,
            tokenContract: _tokenContract,
            tokenId: _tokenId,
            paymentToken: _paymentToken,
            paymentAmount: _paymentAmount,
            allowedInverseFee: _allowedInverseFee
        }));
        emit OrderCreated(orderId, msg.sender, _permittedFiller);
    }

    function fill(uint256 _orderId) external {
        Order storage order = orderBook[_orderId];
        bool isBuyOrder = _checkFillable(order);
        _checkCanFill(order, msg.sender);
        uint256 iFee_ = iFee;
        require(order.allowedInverseFee <= iFee_, "Market: allowed fee too low");

        order.status = OrderStatus.FILLED;
        IERC20 paymentToken = order.paymentToken;
        uint256 paymentAmount = order.paymentAmount;
        (address buyer, address seller) = isBuyOrder
            ? (order.creator, msg.sender)
            : (msg.sender, order.creator);
        order.tokenContract.safeTransferFrom(seller, buyer, order.tokenId);
        paymentToken.safeTransferFrom(buyer, address(this), paymentAmount);
        paymentToken.safeTransfer(seller, paymentAmount * iFee_ / SCALE);
        emit OrderFilled(_orderId, msg.sender, iFee_);
    }

    function cancelOrder(uint256 _orderId) external {
        _cancelOrder(_orderId);
    }

    function cancelOrders(uint256[] memory _orderIds) external {
        for (uint256 i; i < _orderIds.length; i++) {
            _cancelOrder(_orderIds[i]);
        }
    }

    function totalOrders() public view returns (uint256) {
        return orderBook.length;
    }

    function _cancelOrder(uint256 _orderId) internal {
        Order storage order = orderBook[_orderId];
        _checkFillable(order);
        require(order.creator == msg.sender, "Market: unauthorized cancel");
        order.status = OrderStatus.CANCELLED;
        emit OrderCancelled(_orderId);
    }

    function _checkFillable(Order storage _order) internal view returns(bool) {
        bool isBuyOrder = _order.status == OrderStatus.BUY;
        require(
            isBuyOrder || _order.status == OrderStatus.SELL,
            "Market: order not fillable"
        );
        return isBuyOrder;
    }

    function _checkCanFill(Order storage _order, address _filler) internal view {
        address permittedFiller = _order.permittedFiller;
        require(
            permittedFiller == address(0) || permittedFiller == _filler,
            "Market: unauthorized filler"
        );
    }
}
