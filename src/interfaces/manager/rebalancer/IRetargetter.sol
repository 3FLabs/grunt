// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IRetargetterAdmin} from "./IRetargetterAdmin.sol";
import {IRetargetterBatch} from "./IRetargetterBatch.sol";
import {IRetargetterProposals} from "./IRetargetterProposals.sol";

/// @title IRetargetter
/// @author 3F Protocol
/// @notice Composite interface of the Retargetter: admin + batch + proposals.
/// @dev Each sub-interface owns a coherent slice of the public ABI. Consumers can import this
///      composite or pick a single sub-interface depending on what they touch.
interface IRetargetter is IRetargetterAdmin, IRetargetterBatch, IRetargetterProposals {}
