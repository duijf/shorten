{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Main where

import qualified Control.Concurrent.Async as Async
import qualified Control.Concurrent.STM as STM
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Char8 as C8ByteString
import qualified Data.ByteString.Lazy.Char8 as L8ByteString
import qualified Data.Char as Char
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Maybe as Maybe
import qualified Data.Text.Encoding as Text
import qualified Network.HTTP.Types as Http
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified System.Directory as Directory
import qualified Web.FormUrlEncoded as Form

import Control.Concurrent.STM (STM, TVar, TChan)
import Data.HashMap.Strict (HashMap)
import Data.Text (Text)
import GHC.Generics (Generic)
import Web.FormUrlEncoded (FromForm, FormOptions(..))

import Debug.Trace

main :: IO ()
main = do
  state <- openState
  stateChan <- STM.atomically STM.newTChan
  let
    app =
      Warp.runSettings
        (settings 7000)
        (shrtnApp state)
    admin =
      Warp.runSettings
        (settings 7001)
        (mngmntApp state)

  foldr1 Async.race_ [app, admin, writer stateChan]

writer :: TChan ShrtnState -> IO ()
writer stateChan = do
  state <- STM.atomically $ STM.readTChan stateChan
  writeState state
  writer stateChan

-- Warp

settings :: Int -> Warp.Settings
settings port
  = Warp.setPort port
  $ Warp.setHost "*"
  $ Warp.defaultSettings

shrtnApp :: TVar ShrtnState -> Wai.Application
shrtnApp state request respond =
  case Wai.requestMethod (traceShowId request) of
    "GET" -> do
      let slug = Maybe.fromMaybe "" $ Maybe.listToMaybe $ Wai.pathInfo request
      dest <- STM.atomically $ lookupDest slug state
      respond $
        case dest of
          Just d  -> redirectTo (Text.encodeUtf8 d)
          Nothing -> notFound
    "POST" -> do
      body <- Wai.lazyRequestBody request
      case Form.urlDecodeAsForm body of
        Left err -> do
          print err
          print body
          respond badRequest
        Right redirect -> do
          insertRes <- STM.atomically $ insertIfNotExists state (traceShowId redirect)
          case insertRes of
            Success -> respond success
            AlreadyExists -> respond conflict
    _ -> respond methodUnsupported

mngmntApp :: TVar ShrtnState -> Wai.Application
mngmntApp state _request respond = do
  statePrint <- fmap Aeson.encode $ STM.atomically (STM.readTVar state)

  respond $
    Wai.responseLBS
      Http.status200
      [(Http.hContentType, "application/json")]
      statePrint

data Redirect =
  Redirect
  { _redirectSlug :: Text
  , _redirectDest :: Text
  } deriving (Generic, Show)

dropPrefixOptions :: String -> FormOptions
dropPrefixOptions prefix = FormOptions
  { Form.fieldLabelModifier = map Char.toLower . drop (length prefix) }

instance FromForm Redirect where
  fromForm = Form.genericFromForm (dropPrefixOptions "_redirect")

-- State

type Slug = Text
type Dest = Text
type ShrtnState = HashMap Slug Dest

lookupDest :: Slug -> TVar ShrtnState -> STM (Maybe Dest)
lookupDest slug state = do
  redirectMap <- STM.readTVar state
  pure $ HashMap.lookup slug redirectMap

data InsertResult = AlreadyExists | Success

insertIfNotExists :: TVar ShrtnState -> Redirect -> STM InsertResult
insertIfNotExists state redirect = do
  let
    slug = _redirectSlug redirect
    dest = _redirectDest redirect

  redirectMap <- STM.readTVar state
  if HashMap.member slug redirectMap
    then pure AlreadyExists
    else do
      STM.writeTVar state (HashMap.insert slug dest redirectMap)
      pure Success

statePath :: FilePath
statePath = "shrtn.state"

defaultState :: ShrtnState
defaultState = HashMap.insert "" "https://svsticky.nl" HashMap.empty

openState :: IO (TVar ShrtnState)
openState = do
  exists <- Directory.doesFileExist statePath
  if exists
    then do
      contents <- L8ByteString.readFile statePath
      case Aeson.decode contents of
        Just state -> STM.atomically $ STM.newTVar state
        Nothing -> STM.atomically $ STM.newTVar defaultState
    else STM.atomically $ STM.newTVar $ defaultState

writeState :: ShrtnState -> IO ()
writeState state = do
  L8ByteString.writeFile statePath (Aeson.encode state)

-- Wai utils

success :: Wai.Response
success = Wai.responseLBS Http.status200 [] ""

badRequest :: Wai.Response
badRequest = Wai.responseLBS Http.status400 [] ""

notFound :: Wai.Response
notFound = Wai.responseLBS Http.status404 [] ""

methodUnsupported :: Wai.Response
methodUnsupported = Wai.responseLBS Http.status405 [] ""

conflict :: Wai.Response
conflict = Wai.responseLBS Http.status409 [] ""

redirectTo :: C8ByteString.ByteString -> Wai.Response
redirectTo dest =
  Wai.responseLBS
    Http.status302
    [(Http.hLocation, dest)]
    ""
