{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
-- |
-- Module      : Network.GitHub.Client
-- Copyright   : (c) Finlay Thompson, 2015
-- License     : BSD3
-- Maintainer  : finlay.thompson@gmail.com
-- Stability   : experimental

module Network.GitHub.Client
    ( github
    , AuthToken
    , GitHub
    , runGitHub
    , GitHubState(..)
    , HasGitHub
    , embedGitHub
    , EmbedGitHub
    , AddHeaders
    , ReadHeaders
    , Single
    , Paginated
    , setUserAgent
    , resetPagination
    , recurseOff
    , recurseOn
    , pageSize
    , getLinks
    )
where

import Control.Monad (when)
import Control.Monad.Trans.Class
import Control.Monad.Trans.Reader
import Control.Monad.Trans.State
import Control.Monad.Trans.Except (ExceptT, runExceptT)
import Data.Proxy
import GHC.TypeLits
import Data.String
import Data.Text as T

import Servant.API
import Servant.Client

import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Client (newManager, Manager)
import Network.HTTP.Link.Types
import Network.HTTP.Link.Parser (parseLinkHeaderBS)

-- | Token used to authorize access to the GitHub API.
-- see <https://developer.github.com/v3/oauth/>
newtype AuthToken = AuthToken Text deriving (Eq)
instance IsString AuthToken where
    fromString s = AuthToken (fromString s)
instance ToHttpApiData AuthToken where
    toQueryParam (AuthToken t) = T.concat ["token ",  t]

host :: BaseUrl
host = BaseUrl Https "api.github.com" 443 ""

-- | The 'GitHub' monad provides execution context
type GitHub = ReaderT (Maybe AuthToken) (StateT GitHubState (ExceptT ServantError IO))

-- | You need to provide a 'Maybe AuthToken' to lift a 'GitHub' computation
-- into the 'IO' monad.
runGitHub :: GitHub a -> Maybe AuthToken -> IO (Either ServantError a)
runGitHub comp token = do
    manager <- newManager tlsManagerSettings
    runExceptT $ evalStateT (runReaderT comp token) (defGitHubState manager)

-- | Closed type family that adds standard headers to the incoming
-- servant API type. The extra headers are put after any arguments types.
type family AddHeaders a :: * where
    AddHeaders ((sym :: Symbol) :> last)
        = (sym :: Symbol) :> AddHeaders last
    AddHeaders (first :> last)
        = first :> AddHeaders last
    AddHeaders last
        =  Header "User-Agent" Text
        :> Header "Authorization" AuthToken
        :> ReadHeaders last
-- | Closed type family that adds headers necessary for pagination. In particular,
-- it captures the "Link" header from the response.
type family ReadHeaders a :: * where
    ReadHeaders (Get cts [res])
        = QueryParam "page" Int :> QueryParam "per_page" Int
          :> Get cts (Headers '[Header "Link" Text] [res])
    ReadHeaders (Post cts [res])
        = QueryParam "page" Int :> QueryParam "per_page" Int
          :> Post cts (Headers '[Header "Link" Text] [res])
    ReadHeaders (Delete cts [res])
        = QueryParam "page" Int :> QueryParam "per_page" Int
          :> Delete cts (Headers '[Header "Link" Text] [res])
    ReadHeaders (Put cts [res])
        = QueryParam "page" Int :> QueryParam "per_page" Int
          :> Put cts (Headers '[Header "Link" Text] [res])
    ReadHeaders (Patch cts [res])
        = QueryParam "page" Int :> QueryParam "per_page" Int
          :> Patch cts (Headers '[Header "Link" Text] [res])
    ReadHeaders otherwise = otherwise

-- | Client function that returns a single result
type Single a = Maybe Text -> Maybe AuthToken -> Manager -> BaseUrl
             -> ExceptT ServantError IO a

-- | Client function that returns a list of results, and is therefore paginated
type Paginated a = Maybe Text -> Maybe AuthToken
                -> Maybe Int -> Maybe Int
                -> Manager -> BaseUrl
                -> ExceptT ServantError IO (Headers '[Header "Link" Text] [a])

-- | Closed type family for recursively defining the GitHub client funciton types
type family EmbedGitHub a :: * where
    EmbedGitHub (Single a)  = GitHub a
    EmbedGitHub (Paginated a) = GitHub [a]
    EmbedGitHub (a -> b) = a -> EmbedGitHub b

-- | This class defines how the client code is actually called.
class HasGitHub a where
    embedGitHub :: a -> EmbedGitHub a
-- | Instance for the case where we have paginated results
instance HasGitHub (Paginated a) where
    embedGitHub comp = do
        token <- ask
        r <- lift $ gets recurse
        when r resetPagination

        let accumPages acc = do
             ua <- gets useragent
             p  <- gets page
             pp <- gets perPage
             m  <- gets manager
             hres <- lift $ comp (Just ua) token (Just p) (Just pp) m host
             case getHeaders hres of
                 [("Link", lks)] -> modify $ \pg -> pg {links = (parseLinkHeaderBS lks)}
                 _ -> return ()
             let acc' = acc ++ getResponse hres
             rec <- gets recurse
             next <- gets hasNextLink
             if rec && next
                 then do
                     modify $ \pg -> pg {page = p + 1}
                     accumPages acc'
                 else return acc'
        lift $ accumPages []

-- | Instance for the case where we have single result
instance HasGitHub (Single a) where
    embedGitHub comp = do
        token <- ask
        lift $ do
            ua <- gets useragent
            m  <- gets manager
            lift $ comp (Just ua) token m host

-- This instance is a bit too literal. Should be possible to do it reursively
instance HasGitHub (a -> Single b) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> Single c) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> Single d) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> d -> Single e) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> d -> e -> Single f) where
    embedGitHub comp arg = embedGitHub (comp arg)

instance HasGitHub (a -> Paginated b) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> Paginated c) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> Paginated d) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> d -> Paginated e) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> d -> e -> Paginated f) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> d -> e -> g -> Paginated f) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> d -> e -> g -> h -> Paginated f) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> d -> e -> g -> h -> i -> Paginated f) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> d -> e -> g -> h -> i -> k -> Paginated f) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> d -> e -> g -> h -> i -> k -> l -> Paginated f) where
    embedGitHub comp arg = embedGitHub (comp arg)
instance HasGitHub (a -> b -> c -> d -> e -> g -> h -> i -> k -> l -> m -> Paginated f) where
    embedGitHub comp arg = embedGitHub (comp arg)

-- | Wrapper around the servant 'client' function, that takes care of the
-- extra headers that required for the 'GitHub' monad.
github :: (HasClient (AddHeaders api), HasGitHub (Client (AddHeaders api)))
       => Proxy api -> EmbedGitHub (Client (AddHeaders api))
github px = embedGitHub (clientWithHeaders px)

clientWithHeaders :: HasClient (AddHeaders api) => Proxy api -> Client (AddHeaders api)
clientWithHeaders (Proxy :: Proxy api) = client (Proxy :: Proxy (AddHeaders api))


-- | GitHubState options that control which headers are provided to the API
-- and stores the 'Link' header result
data GitHubState
    = GitHubState
    { manager    :: Manager  -- ^ Network Manager
    , perPage    :: Int   -- ^ The number of records returned per page
    , page       :: Int   -- ^ The page number returned
    , links      :: Maybe [Link] -- ^ Contains the returned 'Link' header, if available.
    , recurse    :: Bool  -- ^ Flag to set the recursive mode on
    , useragent  :: Text -- ^ Text to send as "User-agent"
    }
defGitHubState :: Manager -> GitHubState
defGitHubState manager = GitHubState manager 100 1 Nothing True "servant-github"

-- | Overide default value for User-agent header.
-- Note, GitHub requires that a User-agent header be set.
setUserAgent :: Text -> GitHub ()
setUserAgent ua = lift $ modify $ \ghs -> ghs { useragent = ua }

hasNextLink :: GitHubState -> Bool
hasNextLink ghs = maybe False hnl (links ghs)
    where hnl = Prelude.any (\ln -> (Rel, "next") `elem` linkParams ln)

-- | Set next page back to 1, and remove the links
resetPagination :: GitHub ()
resetPagination = lift $ modify $ \ghs -> ghs { page = 1, links = Nothing }

-- | Turn automatic recusive behaviour on and off.
--
-- If recursive is on, paginated results will be automatically
-- followed and concated together.
recurseOff, recurseOn :: GitHub ()
recurseOff =  lift $ modify $ \ghs -> ghs { recurse = False }
recurseOn  =  lift $ modify $ \ghs -> ghs { recurse = True }

-- | The default number of records per page is set to 100. Smaller pages can be
-- set, but not bigger than 100.
pageSize :: Int -> GitHub ()
pageSize ps = lift $ modify $ \ghs -> ghs { perPage = ps }

-- | Return the 'Link' header. This is only set when there are futher pages.
getLinks :: GitHub (Maybe [Link])
getLinks = lift $ gets links
