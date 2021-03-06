{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}

module Foundation where

import           Import.NoFoundation           hiding (unpack, putStrLn, pack)
import           Database.Persist.Sql          (ConnectionPool, runSqlPool)
import           Control.Monad.Logger          (LogSource)
import           Network.Mail.Mime
import qualified Data.Text.Lazy.Encoding
import           Text.Shakespeare.Text         (stext)
import           Text.Blaze.Html.Renderer.Utf8 (renderHtml)
import           Data.Text                     (Text, unpack, pack)
import           Control.Monad                 (join)
import           Custom.Auth.Email
import           Yesod.Core.Types              (Logger)
import qualified Yesod.Core.Unsafe             as Unsafe

-- | The foundation datatype for your application. This can be a good place to
-- keep settings and values requiring initialization before your application
-- starts running, such as database connections. Every handler will have
-- access to the data present here.
data App = App
    { appSettings    :: AppSettings
    , appConnPool    :: ConnectionPool -- ^ Database connection pool.
    , appHttpManager :: Manager
    , appLogger      :: Logger
    }

mkYesodData "App" $(parseRoutesFile "config/routes")

-- | A convenient synonym for database access functions.
type DB a = forall (m :: * -> *).
    (MonadIO m) => ReaderT SqlBackend m a

instance Yesod App where
    approot :: Approot App
    approot = ApprootRequest $ \app req ->
        case appRoot $ appSettings app of
            Nothing -> getApprootText guessApproot app req
            Just root -> root

    -- Store session data on the client in encrypted cookies,
    -- default session idle timeout is 120 minutes
    makeSessionBackend :: App -> IO (Maybe SessionBackend)
    makeSessionBackend _ = Just <$> defaultClientSessionBackend
        120    -- timeout in minutes
        "config/client_session_key.aes"

    -- Yesod Middleware allows you to run code before and after each handler function.
    -- The defaultYesodMiddleware adds the response header "Vary: Accept, Accept-Language" and performs authorization checks.
    -- Some users may also want to add the defaultCsrfMiddleware, which:
    --   a) Sets a cookie with a CSRF token in it.
    --   b) Validates that incoming write requests include that token in either a header or POST parameter.
    -- To add it, chain it together with the defaultMiddleware: yesodMiddleware = defaultYesodMiddleware . defaultCsrfMiddleware
    -- For details, see the CSRF documentation in the Yesod.Core.Handler module of the yesod-core package.
    yesodMiddleware :: ToTypedContent res => Handler res -> Handler res
    yesodMiddleware = defaultYesodMiddleware


    isAuthorized
        :: Route App  -- ^ The route the user is visiting.
        -> Bool       -- ^ Whether or not this is a "write" request.
        -> Handler AuthResult
    -- Routes not requiring authentication.
    isAuthorized (AuthR _) _ = return Authorized
    isAuthorized CommentR _ = return Authorized
    isAuthorized HomeR _ = return Authorized
    isAuthorized FaviconR _ = return Authorized
    isAuthorized RobotsR _ = return Authorized

    -- the profile route requires that the user is authenticated, so we
    -- delegate to that function
    isAuthorized ProfileR _ = isAuthenticated

    -- What messages should be logged. The following includes all messages when
    -- in development, and warnings and errors in production.
    shouldLogIO :: App -> LogSource -> LogLevel -> IO Bool
    shouldLogIO app _source level =
        return $
        appShouldLogAll (appSettings app)
            || level == LevelWarn
            || level == LevelError
            || level == LevelInfo
            || level == LevelDebug

    makeLogger :: App -> IO Logger
    makeLogger = return . appLogger

-- How to run database actions.
instance YesodPersist App where
    type YesodPersistBackend App = SqlBackend
    runDB :: SqlPersistT Handler a -> Handler a
    runDB action = do
        master <- getYesod
        runSqlPool action $ appConnPool master

instance YesodPersistRunner App where
    getDBRunner :: Handler (DBRunner App, Handler ())
    getDBRunner = defaultGetDBRunner appConnPool

instance YesodAuth App where
    type AuthId App = UserId

    authPlugins _ = [authEmail]

    -- Need to find the UserId for the given email address.
    authenticate creds = liftHandler $ runDB $ do
      now <- liftIO getCurrentTime
      eitherUserId <- insertBy $ User (credsIdent creds) Nothing Nothing now False
      return $ Authenticated $
        case eitherUserId of
          Left (Entity userId _) -> userId -- newly added user
          Right userId           -> userId -- existing user

-- Here's all of the email-specific code
instance YesodAuthEmail App where
    type AuthEmailId App = UserId

    addUnverified email verificationToken tokenExpiresAt =
        liftHandler $ runDB $ insert $ User email Nothing (Just verificationToken) tokenExpiresAt False

    addUnverifiedWithPassword email verificationToken tokenExpiresAt saltedPassword =
      liftHandler $ runDB $ insert $ User email (Just saltedPassword) (Just verificationToken) tokenExpiresAt False

    sendVerifyEmail email _ verificationUrl = do
        $(logInfo) $ pack $ "Copy/ Paste this URL in your browser:" ++ unpack verificationUrl

        -- Send email.
        liftIO $ renderSendMail (emptyMail $ Address Nothing "noreply")
            { mailTo = [Address Nothing email]
            , mailHeaders =
                [ ("Subject", "Verify your email address")
                ]
            , mailParts = [[textPart, htmlPart1]]
            }
      where
        textPart = Part
            { partType = "text/plain; charset=utf-8"
            , partEncoding = None
            , partFilename = Nothing
            , partContent = Data.Text.Lazy.Encoding.encodeUtf8
                [stext|
                    Please confirm your email address by clicking on the link below.

                    #{verificationUrl}

                    Thank you
                |]
            , partHeaders = []
            }
        htmlPart1 = Part
            { partType = "text/html; charset=utf-8"
            , partEncoding = None
            , partFilename = Nothing
            , partContent = renderHtml
                [shamlet|
                    <p>Please confirm your email address by clicking on the link below.
                    <p>
                        <a href=#{verificationUrl}>#{verificationUrl}

                    <p>Thank you
                |]
            , partHeaders = []
            }

    sendResetPasswordEmail email _ resetPasswordUrl = do
        $(logInfo) $ pack $ "Copy/ Paste this URL in your browser:" ++ unpack resetPasswordUrl

        -- Send email.
        liftIO $ renderSendMail (emptyMail $ Address Nothing "noreply")
            { mailTo = [Address Nothing email]
            , mailHeaders =
                [ ("Subject", "Reset your password")
                ]
            , mailParts = [[textPart, htmlPart1]]
            }
      where
        textPart = Part
            { partType = "text/plain; charset=utf-8"
            , partEncoding = None
            , partFilename = Nothing
            , partContent = Data.Text.Lazy.Encoding.encodeUtf8
                [stext|
                    Please follow the link below to reset your password.

                    #{resetPasswordUrl}

                    Thank you
                |]
            , partHeaders = []
            }
        htmlPart1 = Part
            { partType = "text/html; charset=utf-8"
            , partEncoding = None
            , partFilename = Nothing
            , partContent = renderHtml
                [shamlet|
                    <p>Please confirm your email address by clicking on the link below.
                    <p>
                        <a href=#{resetPasswordUrl}>#{resetPasswordUrl}
                    <p>Thank you
                |]
            , partHeaders = []
            }


    getVerificationToken = liftHandler . runDB . fmap (join . fmap userVerkey) . get

    getTokenExpiresAt = liftHandler . runDB . fmap (fmap userTokenExpiresAt) . get

    setVerificationToken userId verificationToken = liftHandler $ runDB $ update userId [UserVerkey =. Just verificationToken]

    verifyAccount uid = liftHandler $ runDB $ do
        mu <- get uid
        case mu of
            Nothing -> return Nothing
            Just _ -> do
                update uid [UserVerified =. True]
                return $ Just uid

    getPassword = liftHandler . runDB . fmap (join . fmap userPassword) . get

    setPassword uid pass = liftHandler . runDB $ update uid [UserPassword =. Just pass]

    renewTokenExpiresAt userId newTokenExpiresAt = liftHandler . runDB $ update userId [UserTokenExpiresAt =. newTokenExpiresAt]

    getEmailCreds email = liftHandler $ runDB $ do
        maybeUser <- getBy $ UniqueUser email
        case maybeUser of
            Nothing -> return Nothing
            Just (Entity userId user) -> return $ Just EmailCreds
                { emailCredsId = userId
                , emailCredsAuthId = Just userId
                , emailCredsStatus = userVerified user
                , emailCredsVerkey = userVerkey user
                , emailCredsTokenExpiresAt = userTokenExpiresAt user
                , emailCredsEmail = email
                }

    getEmail = liftHandler . runDB . fmap (fmap userEmail) . get


-- | Access function to determine if a user is logged in.
isAuthenticated :: Handler AuthResult
isAuthenticated = do
    muid <- maybeAuthId
    return $ case muid of
        Nothing -> Unauthorized "You must login to access this page"
        Just _ -> Authorized

instance YesodAuthPersist App

-- This instance is required to use forms. You can modify renderMessage to
-- achieve customized and internationalized form validation messages.
instance RenderMessage App FormMessage where
    renderMessage :: App -> [Lang] -> FormMessage -> Text
    renderMessage _ _ = defaultFormMessage

-- Useful when writing code that is re-usable outside of the Handler context.
-- An example is background jobs that send email.
-- This can also be useful for writing code that works across multiple Yesod applications.
instance HasHttpManager App where
    getHttpManager :: App -> Manager
    getHttpManager = appHttpManager

unsafeHandler :: App -> Handler a -> IO a
unsafeHandler = Unsafe.fakeHandlerGetLogger appLogger

-- Note: Some functionality previously present in the scaffolding has been
-- moved to documentation in the Wiki. Following are some hopefully helpful
-- links:
--
-- https://github.com/yesodweb/yesod/wiki/Sending-email
-- https://github.com/yesodweb/yesod/wiki/Serve-static-files-from-a-separate-domain
-- https://github.com/yesodweb/yesod/wiki/i18n-messages-in-the-scaffolding
