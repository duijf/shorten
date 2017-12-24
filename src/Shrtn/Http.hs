{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Shrtn.Http
  ( new
  , run
  , Config
  , Handle
  ) where

import qualified Control.Concurrent.Async as Async
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Char8 as BSC8
import qualified Data.ByteString.Lazy.Char8 as BSLC8
import           Data.Default (Default, def)
import qualified Data.Either as Either
import qualified Data.Maybe as Maybe
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Network.HTTP.Types as HttpTypes
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.Wai.Middleware.HttpAuth as Auth
import           Web.FormUrlEncoded (FromForm)
import qualified Web.FormUrlEncoded as Form

import qualified Shrtn.State as State

data Config = Config
  { cRedirectPort :: Int
  , cManagementPort :: Int
  , cAuthEnabled :: Bool
  }

instance Default Config where
  def = Config
    { cRedirectPort = 7000
    , cManagementPort = 7001
    , cAuthEnabled = True
    }

data Handle = Handle
  { hConfig :: Config
  , hApp :: IO ()
  , hMngmt :: IO ()
  , hState :: State.Handle
  }

new :: State.Handle -> Config -> IO Handle
new state c@Config{..} =
  pure $ Handle
    { hConfig = c
    , hApp = runWarp cRedirectPort (shrtnApp state)
    , hMngmt = runWarp cManagementPort (basicAuth c $ mngmtApp state)
    , hState = state
    }

runWarp :: Int -> Wai.Application -> IO ()
runWarp port waiApp =
  Warp.runSettings
    ( Warp.setPort port
    $ Warp.setHost "*"
    $ Warp.defaultSettings)
    waiApp

run :: Handle -> IO ()
run Handle{..} = Async.race_ hApp hMngmt

shrtnApp :: State.Handle -> Wai.Application
shrtnApp state request respond =
  case Wai.requestMethod request of
    "GET" -> do
      let slug = Maybe.fromMaybe "" $ Maybe.listToMaybe $ Wai.pathInfo request
      dest <- State.atomically $ State.lookupDest state slug
      respond $
        case dest of
          Just d  -> redirectTo (Text.encodeUtf8 d)
          Nothing -> notFound
    _ -> respond methodUnsupported

mngmtApp :: State.Handle -> Wai.Application
mngmtApp state request respond = do
  case Wai.pathInfo request of
    [] -> case Wai.requestMethod request of
      "GET" -> do
        contents <- BSLC8.readFile "index.html"
        respond $ Wai.responseLBS HttpTypes.status200 [] contents
      _ -> respond $ methodUnsupported
    ["aliases"] -> case Wai.requestMethod request of
      "GET" -> do
        allRedirects <- State.atomically $ State.listAll state
        respond $
          Wai.responseLBS
            HttpTypes.status200
            [(HttpTypes.hContentType, "application/json")]
            (Aeson.encode allRedirects)
      "POST" -> do
        body <- Wai.lazyRequestBody request
        case Form.urlDecodeAsForm body of
          Left _err -> do
            print body
            respond badRequest
          Right r@RandomRedirect{..} -> do
            State.atomically $ State.insertRandom state _redirectDest
            putStrLn $ ":: Created new redirect " ++ show r
            respond success
          Right r@CustomRedirect{..} -> do
            insertRes <- State.atomically $ State.insertIfNotExists state _redirectSlug _redirectDest
            case insertRes of
              State.InsertSuccess -> do
                putStrLn $ ":: Created new redirect " ++ show r
                respond success
              State.SlugAlreadyExists -> respond conflict
      _ -> respond methodUnsupported
    ["style.css"] -> case Wai.requestMethod request of
      "GET" -> do
        contents <- BSLC8.readFile "style.css"
        respond $ Wai.responseLBS HttpTypes.status200 [] contents
      _ -> respond methodUnsupported
    _ -> respond notFound

basicAuth :: Config -> Wai.Middleware
basicAuth Config{..}
  | cAuthEnabled == False = id
  | otherwise = let checkCreds u p = return $ u == "admin" && p == "admin"
                    realm = "shrtn administration"
                in Auth.basicAuth checkCreds realm

data RedirectReq
  = CustomRedirect
    { _redirectSlug :: Text
    , _redirectDest :: Text
    }
  | RandomRedirect
    { _redirectDest :: Text
    }

instance Show RedirectReq where
  show CustomRedirect{..} =
    concatMap Text.unpack ["/",  _redirectSlug, " -> ", _redirectDest]
  show RandomRedirect{..} =
    concatMap Text.unpack ["/random -> ", _redirectDest]

instance FromForm RedirectReq where
  fromForm f
    | Either.isLeft custom = random
    | otherwise     = custom
    where
      custom =
        CustomRedirect
        <$> Form.parseUnique "slug" f
        <*> Form.parseUnique "dest" f
      random =
        RandomRedirect
        <$> Form.parseUnique "dest" f

-- Wai utils

success :: Wai.Response
success = Wai.responseLBS HttpTypes.status200 [] ""

badRequest :: Wai.Response
badRequest = Wai.responseLBS HttpTypes.status400 [] ""

notFound :: Wai.Response
notFound = Wai.responseLBS HttpTypes.status404 [] ""

methodUnsupported :: Wai.Response
methodUnsupported = Wai.responseLBS HttpTypes.status405 [] ""

conflict :: Wai.Response
conflict = Wai.responseLBS HttpTypes.status409 [] ""

redirectTo :: BSC8.ByteString -> Wai.Response
redirectTo dest =
  Wai.responseLBS
    HttpTypes.status302
    [(HttpTypes.hLocation, dest)]
    ""
