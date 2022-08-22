module Hasura.RQL.DDL.Headers
  ( HeaderConf (..),
    HeaderValue (HVEnv, HVValue, HVHeader),
    makeHeadersFromConf,
    toHeadersConf,
  )
where

import Data.Aeson
import Data.CaseInsensitive qualified as CI
import Data.Environment qualified as Env
import Data.Text qualified as T
import Hasura.Base.Error
import Hasura.Base.Instances ()
import Hasura.Incremental (Cacheable)
import Hasura.Prelude
import Network.HTTP.Types qualified as HTTP

data HeaderConf = HeaderConf HeaderName HeaderValue
  deriving (Show, Eq, Generic)

instance NFData HeaderConf

instance Hashable HeaderConf

instance Cacheable HeaderConf

type HeaderName = Text

data HeaderValue = HVValue Text | HVEnv Text | HVHeader Text
  deriving (Show, Eq, Generic)

instance NFData HeaderValue

instance Hashable HeaderValue

instance Cacheable HeaderValue

instance FromJSON HeaderConf where
  parseJSON (Object o) = do
    name <- o .: "name"
    value <- o .:? "value"
    valueFromEnv <- o .:? "value_from_env"
    valueFromHeader <- o .:? "value_from_header"
    case (value, valueFromEnv, valueFromHeader) of
      (Nothing, Nothing, Nothing) -> fail "expecting value, value_from_env or value_from_header keys"
      (Just val, Nothing, Nothing) -> return $ HeaderConf name (HVValue val)
      (Nothing, Just val, Nothing) -> do
        when (T.isPrefixOf "HASURA_GRAPHQL_" val) $
          fail $ "env variables starting with \"HASURA_GRAPHQL_\" are not allowed in value_from_env: " <> T.unpack val
        return $ HeaderConf name (HVEnv val)
      (Nothing, Nothing, Just val) -> do return $ HeaderConf name (HVHeader val)
      _ -> fail "expecting only one of value, value_from_env or value_from_header keys"
  parseJSON _ = fail "expecting object for headers"

instance ToJSON HeaderConf where
  toJSON (HeaderConf name (HVValue val)) = object ["name" .= name, "value" .= val]
  toJSON (HeaderConf name (HVEnv val)) = object ["name" .= name, "value_from_env" .= val]
  toJSON (HeaderConf name (HVHeader val)) = object ["name" .= name, "value_from_header" .= val]

-- | Resolve configuration headers
makeHeadersFromConf ::
  MonadError QErr m => Env.Environment -> [HTTP.Header] -> [HeaderConf] -> m [HTTP.Header]
makeHeadersFromConf env reqHdrs = mapM getHeader
  where
    getHeader hconf =
      ((CI.mk . txtToBs) *** txtToBs)
        <$> case hconf of
          (HeaderConf name (HVValue val)) -> return (name, val)
          (HeaderConf name (HVEnv val)) -> do
            let mEnv = Env.lookupEnv env (T.unpack val)
            case mEnv of
              Nothing -> throw400 NotFound $ "environment variable '" <> val <> "' not set"
              Just envval -> pure (name, T.pack envval)
          (HeaderConf name (HVHeader val)) -> do
            let mHdr = find (\h -> (CI.map bsToTxt (fst h)) == (CI.mk val)) reqHdrs
            case mHdr of
              -- Nothing -> throw400 NotFound $ "request header name '" <> val <> "' not set"
              Just hdr -> pure (name, bsToTxt (snd hdr))
              Nothing -> pure ("OHeader--" <> name, "Not Found") 

-- | Encode headers to HeaderConf
toHeadersConf :: [HTTP.Header] -> [HeaderConf]
toHeadersConf =
  map (uncurry HeaderConf . ((bsToTxt . CI.original) *** (HVValue . bsToTxt)))
