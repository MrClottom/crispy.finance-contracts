// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../lib/FeeTaker.sol";
import "../../lib/interfaces/IHex.sol";
import "../../lib/TwoWayMapping.sol";

contract HexStakeTokenizer is ERC721, FeeTaker {
    using SafeERC20 for IHex;
    using TwoWayMapping for TwoWayMapping.UintToUint;

    IHex public immutable hexToken;
    uint256 public totalIssuedTokens;
    uint256 public totalSupply;
    string public currentBaseURI;

    // stores stakeId to make sure stakes cannot be confused
    mapping(uint256 => uint256) internal _stakeIdOfToken;
    TwoWayMapping.UintToUint internal _tokenIdToStakeIndex;

    constructor(uint256 _fee, IHex _hexToken)
        ERC721("Crispy.finance tokenized hex stakes", "CHXS")
        FeeTaker(_fee)
    {
        hexToken = _hexToken;
    }

    function createStakesFor(
        address _recipient,
        uint256[] memory _stakeAmounts,
        uint256[] memory _stakeDays,
        uint256 _maxFee,
        uint256 _upfrontTotal
    )
        external
    {
        _checkFeeAtMost(_maxFee);
        require(_stakeAmounts.length == _stakeDays.length, "CHXS: Input length mismatch");
        hexToken.safeTransferFrom(msg.sender, address(this), _upfrontTotal);
        uint256 realTotal;
        for (uint256 i; i < _stakeAmounts.length; i++) {
            uint256 stakeAmount = _stakeAmounts[i];
            realTotal += stakeAmount;
            _stakeFor(_recipient, stakeAmount, _stakeDays[i]);
        }
        uint256 feeToTake = realTotal * fee / (SCALE - fee);
        _accountFee(hexToken, feeToTake);
        uint256 stakeCost = realTotal + feeToTake;
        require(_upfrontTotal >= stakeCost, "CHXS: Insufficient funds");
        unchecked {
            uint256 refundAmount = _upfrontTotal - stakeCost;
            if (refundAmount > 0) hexToken.safeTransfer(msg.sender, refundAmount);
        }
    }

    function createStakeFor(
        address _recipient,
        uint256 _totalAmount,
        uint256 _stakeDays,
        uint256 _maxFee
    )
        external
    {
        _checkFeeAtMost(_maxFee);
        hexToken.safeTransferFrom(msg.sender, address(this), _totalAmount);
        uint256 stakeAmount = _takeFee(hexToken, _totalAmount);
        _stakeFor(_recipient, stakeAmount, _stakeDays);
    }

    function setBaseURI(string calldata _newBaseURI) external onlyOwner {
        currentBaseURI = _newBaseURI;
    }

    function unstakeManyTo(address _recipient, uint256[] memory _tokenIds)
        external
    {
        uint256 totalUnstakedAmount;
        for (uint256 i; i < _tokenIds.length; i++) {
            uint256 tokenId = _tokenIds[i];
            uint256 stakeIndex = _tokenIdToStakeIndex.get(tokenId);
            totalUnstakedAmount += _unstake(tokenId, stakeIndex);
        }
        hexToken.safeTransfer(_recipient, totalUnstakedAmount);
    }

    function unstakeTo(address _recipient, uint256 _tokenId) external {
        uint256 stakeIndex = _tokenIdToStakeIndex.get(_tokenId);
        _unstakeTo(_recipient, _tokenId, stakeIndex);
    }

    /* should only be used if there is a bug in the sc and `unstakeTo` no longer
       works */
    function manuallyUnstakeTo(
        address _recipient,
        uint256 _tokenId,
        uint256 _stakeIndex
    )
        external
    {
        _unstakeTo(_recipient, _tokenId, _stakeIndex);
    }

    function getStakeIndex(uint256 _tokenId) public view returns (uint256) {
        return _tokenIdToStakeIndex.get(_tokenId);
    }

    function getTokenId(uint256 _stakeIndex) public view returns (uint256) {
        return _tokenIdToStakeIndex.rget(_stakeIndex);
    }

    function getTokenStakeId(uint256 _tokenId) public view returns (uint256) {
        return _stakeIdOfToken[_tokenId];
    }

    function _stakeFor(
        address _stakeRecipient,
        uint256 _stakeAmount,
        uint256 _stakeDays
    )
        internal
    {
        uint256 newTokenId = totalIssuedTokens++;
        uint256 newStakeIndex = totalSupply;
        _tokenIdToStakeIndex.set(newTokenId, newStakeIndex);
        hexToken.stakeStart(_stakeAmount, _stakeDays);
        _stakeIdOfToken[newTokenId] = _getStakeIdOf(newStakeIndex);
        _safeMint(_stakeRecipient, newTokenId);
    }

    function _unstakeTo(
        address _recipient,
        uint256 _tokenId,
        uint256 _stakeIndex
    )
        internal
    {
        uint256 unstakedAmount = _unstake(_tokenId, _stakeIndex);
        hexToken.safeTransfer(_recipient, unstakedAmount);
    }

    function _unstake(uint256 _tokenId, uint256 _stakeIndex)
        internal returns (uint256 unstakedAmount)
    {
        require(ownerOf(_tokenId) == msg.sender, "CHXS: Not token owner");
        uint256 stakeId = _verifyTokenStakeIndex(_tokenId, _stakeIndex);
        unstakedAmount = _endStake(_tokenId, _stakeIndex, stakeId);
    }

    function _endStake(
        uint256 _tokenId,
        uint256 _stakeIndex,
        uint256 _stakeId
    )
        internal returns (uint256 unstakedAmount)
    {
        _burn(_tokenId);

        // if it wasn't the last stake in the list something got rearanged
        uint256 totalSupply_ = totalSupply;
        if (_stakeIndex != totalSupply_) {
            uint256 topTokenId = _tokenIdToStakeIndex.rget(totalSupply_);
            _tokenIdToStakeIndex.set(topTokenId, _stakeIndex);
        }

        uint256 balanceBefore = hexToken.balanceOf(address(this));
        hexToken.stakeEnd(_stakeIndex, uint40(_stakeId));
        unchecked {
            unstakedAmount = hexToken.balanceOf(address(this)) - balanceBefore;
        }
    }

    function _verifyTokenStakeIndex(uint256 _tokenId, uint256 _stakeIndex)
        internal view returns (uint256 stakeId)
    {
        stakeId = _getStakeIdOf(_stakeIndex);
        require(_stakeIdOfToken[_tokenId] == stakeId, "CHXS: Invalid stake index");
    }

    function _getStakeIdOf(uint256 _stakeIndex) internal view returns (uint256) {
        (uint40 stakeId,,,,,,) = hexToken.stakeLists(address(this), _stakeIndex);
        return uint256(stakeId);
    }

    function _baseURI() internal view override returns (string memory) {
        return currentBaseURI;
    }

    function _mint(address _to, uint256 _tokenId) internal override {
        totalSupply++;
        super._mint(_to, _tokenId);
    }

    function _burn(uint256 _tokenId) internal override {
        totalSupply--;
        super._burn(_tokenId);
    }
}