{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Haskoin.Store.Database.Writer (WriterT , runWriter) where

import           Control.Monad.Reader          (ReaderT (..))
import qualified Control.Monad.Reader          as R
import qualified Data.ByteString.Short         as B.Short
import           Data.HashMap.Strict           (HashMap)
import qualified Data.HashMap.Strict           as M
import           Data.List                     (sortOn)
import           Data.Ord                      (Down (..))
import           Data.Tuple                    (swap)
import           Database.RocksDB              (BatchOp)
import           Database.RocksDB.Query        (deleteOp, insertOp, writeBatch)
import           Haskoin                       (Address, BlockHash, BlockHeight,
                                                Network, OutPoint (..), TxHash,
                                                headerHash, txHash)
import           Haskoin.Store.Common
import           Haskoin.Store.Data
import           Haskoin.Store.Database.Reader
import           Haskoin.Store.Database.Types
import           UnliftIO                      (MonadIO, TVar, atomically,
                                                liftIO, modifyTVar, newTVarIO,
                                                readTVarIO)

data Writer = Writer { getReader :: !DatabaseReader
                     , getState  :: !(TVar Memory) }

type WriterT = ReaderT Writer

instance MonadIO m => StoreReadBase (WriterT m) where
    getNetwork = getNetworkI
    getBestBlock = getBestBlockI
    getBlocksAtHeight = getBlocksAtHeightI
    getBlock = getBlockI
    getTxData = getTxDataI
    getSpender = getSpenderI
    getUnspent = getUnspentI
    getBalance = getBalanceI
    getMempool = getMempoolI

data Memory = Memory
    { hNet
      :: !(Maybe Network)
    , hBest
      :: !(Maybe (Maybe BlockHash))
    , hBlock
      :: !(HashMap BlockHash (Maybe BlockData))
    , hHeight
      :: !(HashMap BlockHeight [BlockHash])
    , hTx
      :: !(HashMap TxHash (Maybe TxData))
    , hSpender
      :: !(HashMap OutPoint (Maybe Spender))
    , hUnspent
      :: !(HashMap OutPoint (Maybe Unspent))
    , hBalance
      :: !(HashMap Address (Maybe Balance))
    , hAddrTx
      :: !(HashMap (Address, TxRef) (Maybe ()))
    , hAddrOut
      :: !(HashMap (Address, BlockRef, OutPoint) (Maybe OutVal))
    , hMempool
      :: !(HashMap TxHash UnixTime)
    } deriving (Eq, Show)

instance MonadIO m => StoreWrite (WriterT m) where
    setBest h =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        setBestH h
    insertBlock b =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertBlockH b
    setBlocksAtHeight h g =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        setBlocksAtHeightH h g
    insertTx t =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertTxH t
    insertSpender p s' =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertSpenderH p s'
    deleteSpender p =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        deleteSpenderH p
    insertAddrTx a t =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertAddrTxH a t
    deleteAddrTx a t =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        deleteAddrTxH a t
    insertAddrUnspent a u =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertAddrUnspentH a u
    deleteAddrUnspent a u =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        deleteAddrUnspentH a u
    addToMempool x t =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
            addToMempoolH x t
    deleteFromMempool x =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
            deleteFromMempoolH x
    setBalance b =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        setBalanceH b
    insertUnspent h =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertUnspentH h
    deleteUnspent p =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        deleteUnspentH p

getLayered :: MonadIO m
           => (Memory -> Maybe a)
           -> DatabaseReaderT m a
           -> WriterT m a
getLayered f g =
    ReaderT $ \Writer { getReader = db, getState = tmem } ->
        f <$> readTVarIO tmem >>= \case
            Just x -> return x
            Nothing -> runReaderT g db

runWriter :: MonadIO m
          => DatabaseReader
          -> WriterT m a
          -> m a
runWriter bdb@DatabaseReader{ databaseHandle = db } f = do
    mem <- runReaderT getMempool bdb
    hm <- newTVarIO (newMemory mem)
    x <- R.runReaderT f Writer { getReader = bdb, getState = hm }
    ops <- hashMapOps <$> readTVarIO hm
    writeBatch db ops
    return x

hashMapOps :: Memory -> [BatchOp]
hashMapOps db =
    bestBlockOp (hBest db) <>
    blockHashOps (hBlock db) <>
    blockHeightOps (hHeight db) <>
    txOps (hTx db) <>
    spenderOps (hSpender db) <>
    balOps (hBalance db) <>
    addrTxOps (hAddrTx db) <>
    addrOutOps (hAddrOut db) <>
    mempoolOp (hMempool db) <>
    unspentOps (hUnspent db)

bestBlockOp :: Maybe (Maybe BlockHash) -> [BatchOp]
bestBlockOp Nothing         = []
bestBlockOp (Just Nothing)  = [deleteOp BestKey]
bestBlockOp (Just (Just b)) = [insertOp BestKey b]

blockHashOps :: HashMap BlockHash (Maybe BlockData) -> [BatchOp]
blockHashOps = map (uncurry f) . M.toList
  where
    f k (Just d) = insertOp (BlockKey k) d
    f k Nothing  = deleteOp (BlockKey k)

blockHeightOps :: HashMap BlockHeight [BlockHash] -> [BatchOp]
blockHeightOps = map (uncurry f) . M.toList
  where
    f = insertOp . HeightKey

txOps :: HashMap TxHash (Maybe TxData) -> [BatchOp]
txOps = map (uncurry f) . M.toList
  where
    f k (Just t) = insertOp (TxKey k) t
    f k Nothing  = deleteOp (TxKey k)

spenderOps :: HashMap OutPoint (Maybe Spender) -> [BatchOp]
spenderOps = map (uncurry f) . M.toList
  where
    f o (Just s) = insertOp (SpenderKey o) s
    f o Nothing  = deleteOp (SpenderKey o)

balOps :: HashMap Address (Maybe Balance) -> [BatchOp]
balOps = map (uncurry f) . M.toList
  where
    f a (Just b) = insertOp (BalKey a) (balanceToVal b)
    f a Nothing  = deleteOp (BalKey a)

addrTxOps :: HashMap (Address, TxRef) (Maybe ()) -> [BatchOp]
addrTxOps = map (uncurry f) . M.toList
  where
    f (a, t) (Just ()) = insertOp (AddrTxKey a t) ()
    f (a, t) Nothing   = deleteOp (AddrTxKey a t)

addrOutOps
    :: HashMap (Address, BlockRef, OutPoint) (Maybe OutVal)
    -> [BatchOp]
addrOutOps = map (uncurry f) . M.toList
  where
    f (a, b, p) (Just l) =
        insertOp
            (AddrOutKey { addrOutKeyA = a
                        , addrOutKeyB = b
                        , addrOutKeyP = p })
            l
    f (a, b, p) Nothing =
        deleteOp AddrOutKey { addrOutKeyA = a
                            , addrOutKeyB = b
                            , addrOutKeyP = p }

mempoolOp :: HashMap TxHash UnixTime -> [BatchOp]
mempoolOp = return . insertOp MemKey . sortOn Down . map swap . M.toList

unspentOps :: HashMap OutPoint (Maybe Unspent) -> [BatchOp]
unspentOps = map (uncurry f) . M.toList
  where
    f p (Just u) = insertOp (UnspentKey p) (snd (unspentToVal u))
    f p Nothing  = deleteOp (UnspentKey p)

getNetworkI :: MonadIO m => WriterT m Network
getNetworkI = getLayered hNet getNetwork

getBestBlockI :: MonadIO m => WriterT m (Maybe BlockHash)
getBestBlockI = getLayered getBestBlockH getBestBlock

getBlocksAtHeightI :: MonadIO m => BlockHeight -> WriterT m [BlockHash]
getBlocksAtHeightI bh = getLayered (getBlocksAtHeightH bh) (getBlocksAtHeight bh)

getBlockI :: MonadIO m => BlockHash -> WriterT m (Maybe BlockData)
getBlockI bh = getLayered (getBlockH bh) (getBlock bh)

getTxDataI :: MonadIO m => TxHash -> WriterT m (Maybe TxData)
getTxDataI th = getLayered (getTxDataH th) (getTxData th)

getSpenderI :: MonadIO m => OutPoint -> WriterT m (Maybe Spender)
getSpenderI op = getLayered (getSpenderH op) (getSpender op)

getBalanceI :: MonadIO m => Address -> WriterT m (Maybe Balance)
getBalanceI a = getLayered (getBalanceH a) (getBalance a)

getUnspentI :: MonadIO m => OutPoint -> WriterT m (Maybe Unspent)
getUnspentI op = getLayered (getUnspentH op) (getUnspent op)

getMempoolI :: MonadIO m => WriterT m [(UnixTime, TxHash)]
getMempoolI =
    ReaderT $ \Writer { getState = tmem } ->
        getMempoolH <$> readTVarIO tmem

newMemory :: [(UnixTime, TxHash)] -> Memory
newMemory mem =
    Memory { hNet     = Nothing
           , hBest    = Nothing
           , hBlock   = M.empty
           , hHeight  = M.empty
           , hTx      = M.empty
           , hSpender = M.empty
           , hUnspent = M.empty
           , hBalance = M.empty
           , hAddrTx  = M.empty
           , hAddrOut = M.empty
           , hMempool = M.fromList (map swap mem)
           }

getBestBlockH :: Memory -> Maybe (Maybe BlockHash)
getBestBlockH = hBest

getBlocksAtHeightH :: BlockHeight -> Memory -> Maybe [BlockHash]
getBlocksAtHeightH h = M.lookup h . hHeight

getBlockH :: BlockHash -> Memory -> Maybe (Maybe BlockData)
getBlockH h = M.lookup h . hBlock

getTxDataH :: TxHash -> Memory -> Maybe (Maybe TxData)
getTxDataH t = M.lookup t . hTx

getSpenderH :: OutPoint -> Memory -> Maybe (Maybe Spender)
getSpenderH op db = M.lookup op (hSpender db)

getBalanceH :: Address -> Memory -> Maybe (Maybe Balance)
getBalanceH a = M.lookup a . hBalance

getMempoolH :: Memory -> [(UnixTime, TxHash)]
getMempoolH = sortOn Down . map swap . M.toList . hMempool

setBestH :: BlockHash -> Memory -> Memory
setBestH h db = db {hBest = Just (Just h)}

insertBlockH :: BlockData -> Memory -> Memory
insertBlockH bd db =
    db { hBlock = M.insert
                  (headerHash (blockDataHeader bd))
                  (Just bd)
                  (hBlock db)
       }

setBlocksAtHeightH :: [BlockHash] -> BlockHeight -> Memory -> Memory
setBlocksAtHeightH hs g db =
    db {hHeight = M.insert g hs (hHeight db)}

insertTxH :: TxData -> Memory -> Memory
insertTxH tx db =
    db {hTx = M.insert (txHash (txData tx)) (Just tx) (hTx db)}

insertSpenderH :: OutPoint -> Spender -> Memory -> Memory
insertSpenderH op s db =
    db { hSpender = M.insert op (Just s) (hSpender db) }

deleteSpenderH :: OutPoint -> Memory -> Memory
deleteSpenderH op db =
    db { hSpender = M.insert op Nothing (hSpender db) }

setBalanceH :: Balance -> Memory -> Memory
setBalanceH bal db =
    db {hBalance = M.insert (balanceAddress bal) (Just bal) (hBalance db)}

insertAddrTxH :: Address -> TxRef -> Memory -> Memory
insertAddrTxH a tr db =
    db { hAddrTx = M.insert (a, tr) (Just ()) (hAddrTx db) }

deleteAddrTxH :: Address -> TxRef -> Memory -> Memory
deleteAddrTxH a tr db =
    db { hAddrTx = M.insert (a, tr) Nothing (hAddrTx db) }

insertAddrUnspentH :: Address -> Unspent -> Memory -> Memory
insertAddrUnspentH a u db =
    let k = (a, unspentBlock u, unspentPoint u)
        v = OutVal { outValAmount = unspentAmount u
                   , outValScript = B.Short.fromShort (unspentScript u)
                   }
     in db { hAddrOut = M.insert k (Just v) (hAddrOut db) }

deleteAddrUnspentH :: Address -> Unspent -> Memory -> Memory
deleteAddrUnspentH a u db =
    let k = (a, unspentBlock u, unspentPoint u)
     in db { hAddrOut = M.insert k Nothing (hAddrOut db) }

addToMempoolH :: TxHash -> UnixTime -> Memory -> Memory
addToMempoolH h t db =
    db { hMempool = M.insert h t (hMempool db) }

deleteFromMempoolH :: TxHash -> Memory -> Memory
deleteFromMempoolH h db =
    db { hMempool = M.delete h (hMempool db) }

getUnspentH :: OutPoint -> Memory -> Maybe (Maybe Unspent)
getUnspentH op db = M.lookup op (hUnspent db)

insertUnspentH :: Unspent -> Memory -> Memory
insertUnspentH u db =
    let k = fst (unspentToVal u)
     in db { hUnspent = M.insert k (Just u) (hUnspent db) }

deleteUnspentH :: OutPoint -> Memory -> Memory
deleteUnspentH op db =
    db { hUnspent = M.insert op Nothing (hUnspent db) }
