{-# LANGUAGE CPP                 #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Internal block logic. Mostly needed for use in 'Pos.Lrc' -- using
-- lrc requires to apply and rollback blocks, but applying many blocks
-- requires triggering lrc recalculations.

module Pos.Block.Logic.Internal
       ( applyBlocksUnsafe
       , rollbackBlocksUnsafe

         -- * Garbage
       , toUpdateBlock
       , toTxpBlock
       ) where

import           Universum

import           Control.Lens         (each, _Wrapped)
import qualified Ether
import           Paths_cardano_sl     (version)

import           Pos.Block.Core       (Block, GenesisBlock, MainBlock, mbTxPayload,
                                       mbUpdatePayload)
import           Pos.Block.Logic.Slog (slogApplyBlocks, slogRollbackBlocks)
import           Pos.Block.Types      (Blund, Undo (undoTx, undoUS))
import           Pos.Core             (IsGenesisHeader, IsMainHeader, epochIndexL, gbBody,
                                       gbHeader)
import           Pos.DB               (SomeBatchOp (..))
import qualified Pos.DB.GState        as GS
import           Pos.Delegation.Logic (delegationApplyBlocks, delegationRollbackBlocks)
import           Pos.Reporting        (reportingFatal)
import           Pos.Txp.Core         (TxPayload)
#ifdef WITH_EXPLORER
import           Pos.Explorer.Txp     (eTxNormalize)
#else
import           Pos.Txp.Logic        (txNormalize)
#endif
import           Pos.Ssc.Class        (SscHelpersClass)
import           Pos.Ssc.Extra        (sscApplyBlocks, sscNormalize, sscRollbackBlocks)
import           Pos.Txp.Settings     (TxpBlock, TxpBlund, TxpGlobalSettings (..))
import           Pos.Update.Core      (UpdateBlock, UpdatePayload)
import           Pos.Update.Logic     (usApplyBlocks, usNormalize, usRollbackBlocks)
import           Pos.Update.Poll      (PollModifier)
import           Pos.Util             (Some (..), spanSafe)
import           Pos.Util.Chrono      (NE, NewestFirst (..), OldestFirst (..))
import           Pos.WorkMode.Class   (WorkMode)

-- | Applies a definitely valid prefix of blocks. This function is unsafe,
-- use it only if you understand what you're doing. That means you can break
-- system guarantees.
--
-- Invariant: all blocks have the same epoch.
applyBlocksUnsafe
    :: forall ssc m . WorkMode ssc m
    => OldestFirst NE (Blund ssc) -> Maybe PollModifier -> m ()
applyBlocksUnsafe blunds0 pModifier =
    reportingFatal version $
    -- It's essential to apply genesis block separately, before
    -- applying other blocks.
    -- That's because applying genesis block may change protocol version
    -- which may potentially change protocol rules.
    -- We would like to avoid dependencies between components, so we have
    -- chosen this approach. Related issue is CSL-660.
    -- Also note that genesis block can be only in the head, because all
    -- blocks are from the same epoch.
    case blunds ^. _Wrapped of
        (b@(Left _,_):|[])     -> app' (b:|[])
        (b@(Left _,_):|(x:xs)) -> app' (b:|[]) >> app' (x:|xs)
        _                      -> app blunds
  where
    app x = applyBlocksUnsafeDo x pModifier
    app' = app . OldestFirst
    -- [CSL-1167] Here we check that invariant holds, but we silently
    -- ignore some blocks if it doesn't.
    -- We should report a fatal error instead.
    (OldestFirst -> blunds, _) =
        spanSafe ((==) `on` view (_1 . epochIndexL)) $ getOldestFirst blunds0

applyBlocksUnsafeDo
    :: forall ssc m . WorkMode ssc m
    => OldestFirst NE (Blund ssc) -> Maybe PollModifier -> m ()
applyBlocksUnsafeDo blunds pModifier = do
    -- Note: it's important to do 'slogApplyBlocks' first, because it
    -- puts blocks in DB.
    slogBatch <- slogApplyBlocks blunds
    TxpGlobalSettings {..} <- Ether.ask'
    usBatch <- SomeBatchOp <$> usApplyBlocks (map toUpdateBlock blocks) pModifier
    delegateBatch <- SomeBatchOp <$> delegationApplyBlocks blocks
    txpBatch <- tgsApplyBlocks $ map toTxpBlund blunds
    sscBatch <- SomeBatchOp <$> sscApplyBlocks blocks Nothing -- TODO: pass not only 'Nothing'
    GS.writeBatchGState
        [ delegateBatch
        , usBatch
        , txpBatch
        , sscBatch
        , slogBatch
        ]
    sscNormalize
#ifdef WITH_EXPLORER
    eTxNormalize
#else
    txNormalize
#endif
    usNormalize
  where
    blocks = fmap fst blunds

-- | Rollback sequence of blocks, head-newest order exepected with
-- head being current tip. It's also assumed that lock on block db is
-- taken.  application is taken already.
rollbackBlocksUnsafe
    :: forall ssc m .(WorkMode ssc m)
    => NewestFirst NE (Blund ssc) -> m ()
rollbackBlocksUnsafe toRollback = reportingFatal version $ do
    slogRoll <- slogRollbackBlocks toRollback
    dlgRoll <- SomeBatchOp <$> delegationRollbackBlocks toRollback
    usRoll <- SomeBatchOp <$> usRollbackBlocks
                  (toRollback & each._2 %~ undoUS
                              & each._1 %~ toUpdateBlock)
    TxpGlobalSettings {..} <- Ether.ask'
    txRoll <- tgsRollbackBlocks $ map toTxpBlund toRollback
    sscBatch <- SomeBatchOp <$> sscRollbackBlocks (fmap fst toRollback)
    GS.writeBatchGState
        [ dlgRoll
        , usRoll
        , txRoll
        , sscBatch
        , slogRoll
        ]

----------------------------------------------------------------------------
-- Garbage
----------------------------------------------------------------------------

-- [CSL-1156] Need something more elegant.
toTxpBlock
    :: forall ssc.
       SscHelpersClass ssc
    => Block ssc -> TxpBlock
toTxpBlock = bimap convertGenesis convertMain
  where
    convertGenesis :: GenesisBlock ssc -> Some IsGenesisHeader
    convertGenesis = Some . view gbHeader
    convertMain :: MainBlock ssc -> (Some IsMainHeader, TxPayload)
    convertMain blk = (Some $ blk ^. gbHeader, blk ^. gbBody . mbTxPayload)

-- [CSL-1156] Yes, definitely need something more elegant.
toTxpBlund
    :: forall ssc.
       SscHelpersClass ssc
    => Blund ssc -> TxpBlund
toTxpBlund = bimap toTxpBlock undoTx

-- [CSL-1156] Sure, totally need something more elegant
toUpdateBlock
    :: forall ssc.
       SscHelpersClass ssc
    => Block ssc -> UpdateBlock
toUpdateBlock = bimap convertGenesis convertMain
  where
    convertGenesis :: GenesisBlock ssc -> Some IsGenesisHeader
    convertGenesis = Some . view gbHeader
    convertMain :: MainBlock ssc -> (Some IsMainHeader, UpdatePayload)
    convertMain blk = (Some $ blk ^. gbHeader, blk ^. gbBody . mbUpdatePayload)
