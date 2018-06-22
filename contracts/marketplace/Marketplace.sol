pragma solidity ^0.4.23;

import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "openzeppelin-solidity/contracts/lifecycle/Destructible.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC721/ERC721Token.sol";

/**
 * @title Interface for contracts conforming to ERC-20
 */
contract ERC20Interface {
  function transferFrom(address from, address to, uint tokens) public returns (bool success);
}

contract Marketplace is Ownable, Pausable, Destructible {
  using SafeMath for uint256;

  ERC20Interface public acceptedToken;

  struct Order {
    // Order ID
    bytes32 id;
    // Owner of the NFT
    address seller;
    // NFT registry address
    address nftAddress;
    // Price (in wei) for the published item
    uint256 price;
    // Time when this sale ends
    uint256 expiresAt;
  }

  mapping (uint256 => Order) public orderByAssetId;

  uint256 public ownerCutPercentage;
  uint256 public publicationFeeInWei;

  /* EVENTS */
  event OrderCreated(
    bytes32 id,
    uint256 indexed assetId,
    address indexed seller, 
    address nftAddress, 
    uint256 priceInWei, 
    uint256 expiresAt
  );
  event OrderSuccessful(
    bytes32 id,
    uint256 indexed assetId, 
    address indexed seller, 
    address nftAddress, 
    uint256 totalPrice, 
    address indexed winner
  );
  event OrderCancelled(
    bytes32 id,
    uint256 indexed assetId, 
    address indexed seller,
    address nftAddress
  );

  event ChangedPublicationFee(uint256 publicationFee);
  event ChangedOwnerCut(uint256 ownerCut);

  /**
    * @dev Constructor for this contract.
    * @param _acceptedToken - Address of the ERC20 accepted for this marketplace
    */
  constructor(address _acceptedToken) public {
    acceptedToken = ERC20Interface(_acceptedToken);
  }

  /**
    * @dev Sets the publication fee that's charged to users to publish items
    * @param publicationFee - Fee amount in wei this contract charges to publish an item
    */
  function setPublicationFee(uint256 publicationFee) onlyOwner public {
    publicationFeeInWei = publicationFee;

    emit ChangedPublicationFee(publicationFeeInWei);
  }

  /**
    * @dev Sets the share cut for the owner of the contract that's
    *  charged to the seller on a successful sale.
    * @param ownerCut - Share amount, from 0 to 100
    */
  function setOwnerCut(uint8 ownerCut) onlyOwner public {
    require(ownerCut < 100);

    ownerCutPercentage = ownerCut;

    emit ChangedOwnerCut(ownerCutPercentage);
  }

  /**
    * @dev Cancel an already published order
    * @param assetId - ID of the published NFT
    * @param nftAddress - Non fungible registry address
    * @param priceInWei - Price in Wei for the supported coin.
    * @param expiresAt - Duration of the order (in hours)
    */
  function createOrder(uint256 assetId, address nftAddress, uint256 priceInWei, uint256 expiresAt) public whenNotPaused {
    require(isContract(nftAddress));

    ERC721 nftRegistry = ERC721(nftAddress);
    address assetOwner = nftRegistry.ownerOf(assetId);

    require(msg.sender == assetOwner);
    require(nftRegistry.isApprovedForAll(assetOwner, address(this)));
    require(priceInWei > 0);
    require(expiresAt > block.timestamp.add(1 minutes));

    bytes32 orderId = keccak256(
      block.timestamp, 
      assetOwner,
      assetId, 
      priceInWei
    );

    orderByAssetId[assetId] = Order({
      id: orderId,
      seller: assetOwner,
      nftAddress: nftAddress,
      price: priceInWei,
      expiresAt: expiresAt
    });

    // Check if there's a publication fee and
    // transfer the amount to marketplace owner.
    if (publicationFeeInWei > 0) {
      acceptedToken.transferFrom(
        msg.sender,
        owner,
        publicationFeeInWei
      );
    }

    emit OrderCreated(
      orderId,
      assetId, 
      assetOwner,
      nftAddress,
      priceInWei, 
      expiresAt
    );
  }

  /**
    * @dev Cancel an already published order
    *  can only be canceled by seller or the contract owner.
    * @param assetId - ID of the published NFT
    */
  function cancelOrder(uint256 assetId) public whenNotPaused {
    require(orderByAssetId[assetId].seller == msg.sender || msg.sender == owner);

    bytes32 orderId = orderByAssetId[assetId].id;
    address orderSeller = orderByAssetId[assetId].seller;
    address nftAddress = orderByAssetId[assetId].nftAddress;
    delete orderByAssetId[assetId];

    emit OrderCancelled(orderId, assetId, orderSeller, nftAddress);
  }

  /**
    * @dev Executes the sale for a published NTF
    * @param assetId - ID of the published NFT
    * @param price - Order price 
    */
  function executeOrder(uint256 assetId, uint256 price) public whenNotPaused {
    address seller = orderByAssetId[assetId].seller;
    address nftAddress = orderByAssetId[assetId].nftAddress;

    ERC721 nftRegistry = ERC721(nftAddress);

    require(seller != address(0));
    require(seller != msg.sender);
    require(orderByAssetId[assetId].price == price);
    require(block.timestamp < orderByAssetId[assetId].expiresAt);
    require(seller == nftRegistry.ownerOf(assetId));

    uint saleShareAmount = 0;

    if (ownerCutPercentage > 0) {
      // Calculate sale share
      saleShareAmount = price.mul(ownerCutPercentage).div(100);

      // Transfer share amount for marketplace Owner.
      acceptedToken.transferFrom(
        msg.sender,
        owner,
        saleShareAmount
      );
    }

    // Transfer sale amount to seller
    acceptedToken.transferFrom(
      msg.sender,
      seller,
      price.sub(saleShareAmount)
    );

    // Transfer asset owner
    nftRegistry.safeTransferFrom(
      seller,
      msg.sender,
      assetId
    );


    bytes32 orderId = orderByAssetId[assetId].id;
    delete orderByAssetId[assetId];

    emit OrderSuccessful(
      orderId,
      assetId,
      seller,
      nftAddress,
      price,
      msg.sender
    );
  }

  function isContract(address addr) internal view returns (bool) {
    uint256 size;
    assembly { size := extcodesize(addr) }  
    return size > 0;
  }
}