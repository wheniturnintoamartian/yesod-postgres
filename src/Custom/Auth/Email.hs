{-# LANGUAGE ConstrainedClassMethods #-}
{-# LANGUAGE DeriveDataTypeable      #-}
{-# LANGUAGE FlexibleContexts        #-}
{-# LANGUAGE OverloadedStrings       #-}
{-# LANGUAGE PatternGuards           #-}
{-# LANGUAGE Rank2Types              #-}
{-# LANGUAGE ScopedTypeVariables     #-}
{-# LANGUAGE TemplateHaskell         #-}
{-# LANGUAGE TypeFamilies            #-}

-- | A Yesod plugin for Authentication via e-mail
--
-- This plugin works out of the box by only setting a few methods on
-- the type class that tell the plugin how to interoperate with your
-- user data storage (your database).  However, almost everything is
-- customizeable by setting more methods on the type class.  In
-- addition, you can send all the form submissions via JSON and
-- completely control the user's flow.
--
-- This is a standard registration e-mail flow
--
-- 1. A user registers a new e-mail address, and an e-mail is sent there
-- 2. The user clicks on the registration link in the e-mail. Note that
--   at this point they are actually logged in (without a
--   password). That means that when they log out they will need to
--  reset their password.
-- 3. The user sets their password and is redirected to the site.
-- 4. The user can now
--
--     * logout and sign in
--     * reset their password
--
-- = Using JSON Endpoints
--
-- We are assuming that you have declared auth route as follows
--
-- @
--    /auth AuthR Auth getAuth
-- @
--
-- If you are using a different route, then you have to adjust the
-- endpoints accordingly.
--
--     * Registration
--
-- @
--       Endpoint: \/auth\/page\/email\/register
--       Method: POST
--       JSON Data: {
--                      "email": "myemail@domain.com",
--                      "password": "myStrongPassword" (optional)
--                  }
-- @
--
--     * Forgot password
--
-- @
--       Endpoint: \/auth\/page\/email\/forgot-password
--       Method: POST
--       JSON Data: { "email": "myemail@domain.com" }
-- @
--
--     * Login
--
-- @
--       Endpoint: \/auth\/page\/email\/login
--       Method: POST
--       JSON Data: {
--                      "email": "myemail@domain.com",
--                      "password": "myStrongPassword"
--                  }
-- @
--
--     * Set new password
--
-- @
--       Endpoint: \/auth\/page\/email\/set-password
--       Method: POST
--       JSON Data: {
--                       "new": "newPassword",
--                       "confirm": "newPassword",
--                       "current": "currentPassword"
--                  }
-- @
--
--  Note that in the set password endpoint, the presence of the key
--  "current" is dependent on how the 'needOldPassword' is defined in
--  the instance for 'YesodAuthEmail'.
module Custom.Auth.Email
      -- * Plugin
  ( authEmail
  , YesodAuthEmail(..)
  , EmailCreds(..)
  , saltPass
      -- * Routes
  , verifyR
  , isValidPass
      -- * Types
  , Email
  , VerKey
  , VerUrl
  , SaltedPass
  , VerStatus
  , Identifier
     -- * Misc
  , loginLinkKey
  , setLoginLinkKey
  ) where

import           Control.Applicative           ((<$>))
import qualified Crypto.Hash                   as H
import qualified Crypto.Nonce                  as Nonce
import           Custom.Auth
import qualified Custom.Auth.Message           as Msg
import           Data.Aeson.Types              (Parser, Result (..),
                                                parseEither, withObject)
import           Data.ByteArray                (convert)
import           Data.ByteString.Base16        as B16
import           Data.Text                     (Text)
import qualified Data.Text                     as TS
import qualified Data.Text                     as T
import           Data.Text.Encoding            (decodeUtf8With, encodeUtf8)
import qualified Data.Text.Encoding            as TE
import           Data.Text.Encoding.Error      (lenientDecode)
import           Data.Time                     (addUTCTime, getCurrentTime)
import           Safe                          (readMay)
import           System.IO.Unsafe              (unsafePerformIO)
import qualified Text.Email.Validate
import qualified Yesod.Auth.Util.PasswordStore as PS
import           Yesod.Core

verifyR :: Text -> Text -> AuthRoute
verifyR eid verkey = PluginR "email" path
  where
    path = "verify" : eid : [verkey]

setPasswordR :: Text -> Text -> AuthRoute
setPasswordR encryptedUserId verificationKey = PluginR "email" path
  where
    path = "set-password" : encryptedUserId : [verificationKey]

type Email = Text

type VerKey = Text

type VerUrl = Text

type SaltedPass = Text

type VerStatus = Bool

type Identifier = Text

data EmailCreds site = EmailCreds
  { emailCredsId     :: AuthEmailId site
  , emailCredsAuthId :: Maybe (AuthId site)
  , emailCredsStatus :: VerStatus
  , emailCredsVerkey :: Maybe VerKey
  , emailCredsEmail  :: Email
  }

class (YesodAuth site, PathPiece (AuthEmailId site), (RenderMessage site Msg.AuthMessage), Show (AuthEmailId site)) =>
      YesodAuthEmail site
  where
  type AuthEmailId site
  addUnverified :: Email -> VerKey -> AuthHandler site (AuthEmailId site)
  addUnverifiedWithPass :: Email -> VerKey -> SaltedPass -> AuthHandler site (AuthEmailId site)
  addUnverifiedWithPass email verkey _ = addUnverified email verkey
  sendVerifyEmail :: Email -> VerKey -> VerUrl -> AuthHandler site ()
  sendResetPasswordEmail :: Email -> VerKey -> VerUrl -> AuthHandler site ()
  getVerifyKey :: AuthId site -> AuthHandler site (Maybe VerKey)
  setVerifyKey :: AuthEmailId site -> VerKey -> AuthHandler site ()
  hashAndSaltPassword :: Text -> AuthHandler site SaltedPass
  hashAndSaltPassword = liftIO . saltPass
  verifyPassword :: Text -> SaltedPass -> AuthHandler site Bool
  verifyPassword plain salted = return $ isValidPass plain salted
    -- | Verify the email address on the given account.
    --
    -- __/Warning!/__ If you have persisted the @'AuthEmailId' site@
    -- somewhere, this method should delete that key, or make it unusable
    -- in some fashion. Otherwise, the same key can be used multiple times!
    --
    -- See <https://github.com/yesodweb/yesod/issues/1222>.
    --
    -- @since 1.1.0
  verifyAccount :: AuthId site -> AuthHandler site (Maybe (AuthId site))
    -- | Get the salted password for the given account.
    --
    -- @since 1.1.0
  getPassword :: AuthId site -> AuthHandler site (Maybe SaltedPass)
    -- | Set the salted password for the given account.
    --
    -- @since 1.1.0
  setPassword :: AuthId site -> SaltedPass -> AuthHandler site ()
    -- | Get the credentials for the given @Identifier@, which may be either an
    -- email address or some other identification (e.g., username).
    --
    -- @since 1.2.0
  getEmailCreds :: Identifier -> AuthHandler site (Maybe (EmailCreds site))
    -- | Get the email address for the given email ID.
    --
    -- @since 1.1.0
  getEmail :: AuthId site -> AuthHandler site (Maybe Email)
    -- | Generate a random alphanumeric string.
    --
    -- @since 1.1.0
  randomKey :: site -> IO VerKey
  randomKey _ = Nonce.nonce128urlT defaultNonceGen
    -- | Does the user need to provide the current password in order to set a
    -- new password?
    --
    -- Default: if the user logged in via an email link do not require a password.
    --
    -- @since 1.2.1
  needOldPassword :: AuthId site -> AuthHandler site Bool
  needOldPassword aid' = do
    mkey <- lookupSession loginLinkKey
    case mkey >>= readMay . TS.unpack of
      Just (aidT, time)
        | Just aid <- fromPathPiece aidT
        , toPathPiece (aid `asTypeOf` aid') == toPathPiece aid' -> do
          now <- liftIO getCurrentTime
          return $ addUTCTime (60 * 30) time <= now
      _ -> return True
    -- | Check that the given plain-text password meets minimum security standards.
    --
    -- Default: password is at least three characters.
  checkPasswordSecurity :: AuthId site -> Text -> AuthHandler site (Either Text ())
  checkPasswordSecurity _ x
    | TS.length x >= 3 = return $ Right ()
    | otherwise = return $ Left "Password must be at least three characters"
    -- | Response after sending a confirmation email.
    --
    -- @since 1.2.2
  confirmationEmailSentResponse :: Text -> AuthHandler site Value
  confirmationEmailSentResponse identifier = do
    mr <- getMessageRender
    provideJsonMessage (mr msg)
    where
      msg = Msg.ConfirmationEmailSent identifier
  -- | Response after sending a confirmation email.
  resetPasswordEmailSentResponse :: Text -> AuthHandler site Value
  resetPasswordEmailSentResponse identifier = do
    mr <- getMessageRender
    provideJsonMessage (mr msg)
    where
      msg = Msg.ResetPasswordEmailSent identifier
    -- | Additional normalization of email addresses, besides standard canonicalization.
    --
    -- Default: Lower case the email address.
    --
    -- @since 1.2.3
  normalizeEmailAddress :: site -> Text -> Text
  normalizeEmailAddress _ = TS.toLower

authEmail :: (YesodAuthEmail m) => AuthPlugin m
authEmail = AuthPlugin "email" dispatch
  where
    dispatch "POST" ["register"] = postRegisterR >>= sendResponse
    dispatch "POST" ["forgot-password"] = postForgotPasswordR >>= sendResponse
    dispatch "GET" ["verify", userId, verificationKey] =
      case fromPathPiece userId of
        Nothing      -> notFound
        Just userId' -> getVerifyR userId' verificationKey >>= sendResponse
    dispatch "POST" ["login"] = postLoginR >>= sendResponse
    dispatch "POST" ["set-password", userId, verificationKey] =
      case fromPathPiece userId of
        Nothing -> notFound
        Just userId' -> postPasswordR userId' verificationKey >>= sendResponse
    dispatch _ _ = notFound

registerHelper ::
     YesodAuthEmail master
  => Bool -- ^ forgot password?
  -> AuthHandler master Value
registerHelper forgotPassword = do
  checkCsrfHeaderOrParam defaultCsrfHeaderName defaultCsrfParamName -- Check if csrf token is added in request
  jsonRegisterForgotPasswordCredsParseResult <-
    do (creds :: Result Value) <- parseCheckJsonBody
       case creds of
         Error errorMessage -> do
           $(logError) $ T.pack errorMessage
           return MalformedJSON
         Success val -> do
           $(logInfo) $ T.pack $ show val
           let eitherEmailField = parseEither parseEmailField val
           $(logInfo) $ T.pack $ show eitherEmailField
           case eitherEmailField of
             Left missingEmailError -> do
               $(logError) $ T.pack $ show missingEmailError
               return MissingEmail
             Right email -> do
               $(logInfo) $ T.pack $ show email
               if forgotPassword
                 then do
                   return $ ForgotPasswordCreds email
                 else do
                   let eitherPasswordField = parseEither parsePasswordField val
                   $(logInfo) $ T.pack $ show eitherPasswordField
                   case eitherPasswordField of
                     Left missingPasswordError -> do
                       $(logError) $ T.pack $ show missingPasswordError
                       return MissingPassword
                     Right password -> do
                       return $ LoginRegisterCreds email password
  $(logInfo) $ T.pack $ show jsonRegisterForgotPasswordCredsParseResult
  messageRender <- getMessageRender
  y <- getYesod -- It is used to produce randomKey
  emailIdentifier <-
    case jsonRegisterForgotPasswordCredsParseResult of
      MalformedJSON -> do
        $(logError) $ messageRender Msg.MalformedJSONMessage
        return $ Left Msg.MalformedJSONMessage
      MissingEmail -> do
        $(logError) $ messageRender Msg.MissingEmailMessage
        return $ Left Msg.MissingEmailMessage
      MissingPassword -> do
        $(logError) $ messageRender Msg.MissingPasswordMessage
        return $ Left Msg.MissingPasswordMessage
      LoginRegisterCreds email password
        | Just email' <- Text.Email.Validate.canonicalizeEmail (encodeUtf8 email) -- canonicalize email
         -> do
          let loginRegisterCreds =
                LoginRegisterCreds (normalizeEmailAddress y $ decodeUtf8With lenientDecode email') password
          $(logInfo) $ T.pack $ show loginRegisterCreds
          return $ Right loginRegisterCreds
        | otherwise -- or return error message that the value entered as email is not one
         -> do
          $(logError) $ messageRender Msg.InvalidEmailAddress
          return $ Left Msg.InvalidEmailAddress
      ForgotPasswordCreds email
        | Just email' <- Text.Email.Validate.canonicalizeEmail (encodeUtf8 email) -> do
          let forgotPasswordCreds = ForgotPasswordCreds (normalizeEmailAddress y $ decodeUtf8With lenientDecode email')
          $(logInfo) $ T.pack $ show forgotPasswordCreds
          return $ Right forgotPasswordCreds
        | otherwise -> do
          $(logError) $ messageRender Msg.InvalidEmailAddress
          return $ Left Msg.InvalidEmailAddress
  case emailIdentifier of
    Left message -> loginErrorMessageI message
    Right (LoginRegisterCreds email password) -> do
      mecreds <- getEmailCreds email
      registerCreds <-
        case mecreds of
          Just (EmailCreds lid _ verStatus (Just key) email') -> return $ Just (lid, verStatus, key, email')
          Nothing -- The user has not been registered yet
           -> do
            key <- liftIO $ randomKey y
            lid <-
              do salted <- hashAndSaltPassword password
                 addUnverifiedWithPass email key salted
            return $ Just (lid, False, key, email)
          _ -> do
            $(logError) $ messageRender $ Msg.UserRowNotInValidState email
            return Nothing
      case registerCreds of
        Just creds1@(_, False, _, _) -> sendConfirmationEmail creds1
        Just (_, True, _, _) -> loginErrorMessageI Msg.AlreadyRegistered
        _ -> loginErrorMessageI Msg.RegistrationFailure
      where sendConfirmationEmail (lid, _, verKey, email') = do
              render <- getUrlRender
              tp <- getRouteToParent
              let verUrl = render $ tp $ verifyR (toPathPiece lid) verKey
              sendVerifyEmail email' verKey verUrl
              confirmationEmailSentResponse email'
    Right (ForgotPasswordCreds email) -> do
      mecreds <- getEmailCreds email
      registerCreds <-
        case mecreds of
          Just (EmailCreds lid _ verStatus (Just key) email') -> return $ Just (lid, verStatus, key, email')
          _ -> do
            $(logError) $ messageRender $ Msg.UserRowNotInValidState email
            return Nothing
      case registerCreds of
        Nothing     -> loginErrorMessageI Msg.ForgotPasswordFailure
        Just creds1 -> sendResetPasswordEmailHandler creds1
      where sendResetPasswordEmailHandler (lid, _, verKey, email') = do
              render <- getUrlRender
              tp <- getRouteToParent
              let verUrl = render $ tp $ setPasswordR (toPathPiece lid) verKey
              sendResetPasswordEmail email' verKey verUrl
              resetPasswordEmailSentResponse email'
    _ -> do
      $(logError) $ T.pack "Invalid pattern match"
      loginErrorMessageI Msg.RegistrationFailure

postRegisterR :: YesodAuthEmail master => AuthHandler master Value
postRegisterR = registerHelper False

postForgotPasswordR :: YesodAuthEmail master => AuthHandler master Value
postForgotPasswordR = registerHelper True

getVerifyR :: YesodAuthEmail site => AuthId site -> Text -> AuthHandler site Value
getVerifyR userId verificationKey = do
  realKey <- getVerifyKey userId
  memail <- getEmail userId
  mr <- getMessageRender
  case (realKey == Just verificationKey, memail) of
    (True, Just email) -> do
      muid <- verifyAccount userId
      case muid of
        Nothing -> invalidKey mr
        Just uid -> do
          setCreds False $ Creds "email-verify" email [("verifiedEmail", email)] -- FIXME uid?
          setLoginLinkKey uid
          let msgAv = Msg.AddressVerified
          provideJsonMessage $ mr msgAv
    _ -> invalidKey mr
  where
    msgIk = Msg.InvalidKey
    invalidKey mr = messageJson401 (mr msgIk)

parseEmailField :: Value -> Parser Text
parseEmailField =
  withObject
    "email"
    (\obj -> do
       email' <- obj .: "email"
       return email')

parsePasswordField :: Value -> Parser Text
parsePasswordField =
  withObject
    "password"
    (\obj -> do
       password' <- obj .: "password"
       return password')

type Password = Text

data JSONLoginCredsParseResult
  = MalformedJSON
  | MissingEmail
  | MissingPassword
  | LoginRegisterCreds Email
                       Password
  | ForgotPasswordCreds Email
  deriving (Show)

data LoginResult
  = PasswordNotSet Email
  | AccountNotVerified Email
  | PasswordMismatch Email
  | LoginFailureEmail Email
  | LoginFailure
  | LoginValidationSuccess Email
  deriving (Show)

postLoginR :: YesodAuthEmail master => AuthHandler master Value
postLoginR = do
  jsonLoginCredsParseResult <-
    do (creds :: Result Value) <- parseCheckJsonBody
       case creds of
         Error errorMessage -> do
           $(logError) $ T.pack errorMessage
           return MalformedJSON
         Success val -> do
           $(logInfo) $ T.pack $ show val
           let eitherEmailField = parseEither parseEmailField val
           $(logInfo) $ T.pack $ show eitherEmailField
           case eitherEmailField of
             Left missingEmailError -> do
               $(logError) $ T.pack $ show missingEmailError
               return MissingEmail
             Right email -> do
               $(logInfo) $ T.pack $ show email
               let eitherPasswordField = parseEither parsePasswordField val
               $(logInfo) $ T.pack $ show eitherPasswordField
               case eitherPasswordField of
                 Left missingPasswordError -> do
                   $(logError) $ T.pack $ show missingPasswordError
                   return MissingPassword
                 Right password -> do
                   return $ LoginRegisterCreds email password
  $(logInfo) $ T.pack $ show jsonLoginCredsParseResult
  messageRender <- getMessageRender
  case jsonLoginCredsParseResult of
    MalformedJSON -> loginErrorMessageI Msg.MalformedJSONMessage
    MissingEmail -> loginErrorMessageI Msg.MissingEmailMessage
    MissingPassword -> loginErrorMessageI Msg.MissingPasswordMessage
    LoginRegisterCreds email password
      | Just email' <- Text.Email.Validate.canonicalizeEmail (encodeUtf8 email) -> do
        emailCreds <- getEmailCreds $ decodeUtf8With lenientDecode email'
        loginResult <-
          case (emailCreds >>= emailCredsAuthId, emailCredsEmail <$> emailCreds, emailCredsStatus <$> emailCreds) of
            (Just aid, Just email'', Just True) -> do
              mrealpass <- getPassword aid
              case mrealpass of
                Nothing -> return $ PasswordNotSet email''
                Just realpass -> do
                  passValid <- verifyPassword password realpass
                  return $
                    if passValid
                      then LoginValidationSuccess email''
                      else PasswordMismatch email''
            (_, Just email'', Just False) -> do
              $(logError) $ messageRender $ Msg.AccountNotVerified email''
              return $ AccountNotVerified email''
            (Nothing, Just email'', _) -> do
              $(logError) $ messageRender $ Msg.LoginFailureEmail email''
              return $ LoginFailureEmail email''
            _ -> do
              $(logError) $ messageRender Msg.LoginFailure
              return LoginFailure
        let isEmail = Text.Email.Validate.isValid $ encodeUtf8 email
        case loginResult of
          LoginValidationSuccess email'' ->
            setCredsRedirect $
            Creds
              (if isEmail
                 then "email"
                 else "username")
              email''
              [("verifiedEmail", email'')]
          PasswordNotSet email'' -> do
            $(logError) $ messageRender $ Msg.PasswordNotSet email''
            loginErrorMessageI $
              if isEmail
                then Msg.InvalidEmailPass
                else Msg.InvalidUsernamePass
          PasswordMismatch email'' -> do
            $(logError) $ messageRender $ Msg.PasswordMismatch email''
            loginErrorMessageI $
              if isEmail
                then Msg.InvalidEmailPass
                else Msg.InvalidUsernamePass
          AccountNotVerified email'' -> do
            $(logError) $ messageRender $ Msg.AccountNotVerified email''
            loginErrorMessageI $ Msg.AccountNotVerified email''
          LoginFailureEmail email'' -> do
            $(logError) $ messageRender $ Msg.LoginFailureEmail email''
            loginErrorMessageI Msg.LoginFailure
          LoginFailure -> do
            $(logError) $ messageRender Msg.LoginFailure
            loginErrorMessageI Msg.LoginFailure
      | otherwise -> do
        $(logError) $ messageRender Msg.InvalidEmailAddress
        loginErrorMessageI Msg.InvalidEmailAddress
    _ -> do
      $(logError) $ T.pack "Invalid pattern match"
      loginErrorMessageI Msg.RegistrationFailure

--getPasswordR :: YesodAuthEmail master => AuthHandler master Value
--getPasswordR = do
--    maid <- maybeAuthId
--    case maid of
--        Nothing -> loginErrorMessageI Msg.BadSetPass
--        Just _ -> do
--            needOld <- maybe (return True) needOldPassword maid
--            provideJsonMessage ("Ok" :: Text)
parseNewPasswordField :: Value -> Parser (Text)
parseNewPasswordField =
  withObject
    "newPassword"
    (\obj -> do
       newPassword <- obj .: "new"
       return newPassword)

parseConfirmPasswordField :: Value -> Parser (Text)
parseConfirmPasswordField =
  withObject
    "confirmPassword"
    (\obj -> do
       confirm <- obj .: "confirm"
       return confirm)

data JSONResetPasswordCredsParseResult
  = MalformedResetPasswordJSON
  | MissingNewPassword
  | MissingConfirmPassword
  | ResetPasswordCreds Password
                       Password
  deriving (Show)

postPasswordR :: YesodAuthEmail site => AuthId site -> Text -> AuthHandler site Value
postPasswordR userId verificationKey = do
  (creds :: Result Value) <- parseCheckJsonBody
  jsonResetPasswordCredsParseResult <-
       case creds of
         Error errorMessage -> do
           $(logError) $ T.pack errorMessage
           return MalformedResetPasswordJSON
         Success val -> do
           $(logInfo) $ T.pack $ show val
           let eitherNewPasswordField = parseEither parseNewPasswordField val
           $(logInfo) $ T.pack $ show eitherNewPasswordField
           case eitherNewPasswordField of
             Left missingNewPasswordError -> do
               $(logError) $ T.pack $ show missingNewPasswordError
               return MissingNewPassword
             Right newPassword -> do
               $(logInfo) $ T.pack $ show newPassword
               let eitherConfirmPasswordField = parseEither parseConfirmPasswordField val
               $(logInfo) $ T.pack $ show eitherConfirmPasswordField
               case eitherConfirmPasswordField of
                 Left missingConfirmPasswordError -> do
                   $(logError) $ T.pack $ show missingConfirmPasswordError
                   return MissingConfirmPassword
                 Right confirmPassword ->
                   return $ ResetPasswordCreds newPassword confirmPassword
  messageRender <- getMessageRender
  case jsonResetPasswordCredsParseResult of
    MalformedResetPasswordJSON -> loginErrorMessageI Msg.MalformedJSONMessage
    MissingNewPassword -> do
      $(logError) $ messageRender $ Msg.MissingNewPasswordInternalMessage $ T.pack $ show userId
      loginErrorMessageI Msg.MissingNewPasswordMessage
    MissingConfirmPassword -> do
      $(logError) $ messageRender $ Msg.MissingConfirmPasswordInternalMessage $ T.pack $ show userId
      loginErrorMessageI Msg.MissingConfirmPasswordMessage
    ResetPasswordCreds newPassword confirmPassword
      | newPassword == confirmPassword -> do
          isSecure <- checkPasswordSecurity userId newPassword
          case isSecure of
            Left e -> do
              $(logError) e
              loginErrorMessage e
            Right () -> do
              storedVerificationKey <- getVerifyKey userId
              case (storedVerificationKey, verificationKey) of
                (Just value, vk)
                  | value == vk -> do
                      salted <- hashAndSaltPassword newPassword
                      $(logInfo) $ T.pack $ "New salted password for user with userId " ++ show userId ++ " is " ++ T.unpack salted
                      setPassword userId salted
                      $(logInfo) $ T.pack "New password updated"
                      deleteSession loginLinkKey
                      messageJson200 $ messageRender Msg.PassUpdated
                  | otherwise -> do
                      $(logError) $ messageRender $ Msg.InvalidVerificationKeyInternalMessage (T.pack $ show userId)
                        vk value
                      loginErrorMessageI Msg.InvalidVerificationKey
                (Nothing, vk) -> do
                  $(logError) $ messageRender $ Msg.MissingVerificationKeyInternalMessage (T.pack $ show userId) vk
                  loginErrorMessageI Msg.InvalidVerificationKey
      | otherwise -> do
          $(logError) $ messageRender $ Msg.PassMismatchInternalMessage $ T.pack $ show userId
          loginErrorMessageI Msg.PassMismatch

saltLength :: Int
saltLength = 5

-- | Salt a password with a randomly generated salt.
saltPass :: Text -> IO Text
saltPass = fmap (decodeUtf8With lenientDecode) . flip PS.makePassword 16 . encodeUtf8

saltPass' :: String -> String -> String
saltPass' salt pass =
  salt ++
  T.unpack (TE.decodeUtf8 $ B16.encode $ convert (H.hash (TE.encodeUtf8 $ T.pack $ salt ++ pass) :: H.Digest H.MD5))

isValidPass ::
     Text -- ^ cleartext password
  -> SaltedPass -- ^ salted password
  -> Bool
isValidPass ct salted = PS.verifyPassword (encodeUtf8 ct) (encodeUtf8 salted) || isValidPass' ct salted

isValidPass' ::
     Text -- ^ cleartext password
  -> SaltedPass -- ^ salted password
  -> Bool
isValidPass' clear' salted' =
  let salt = take saltLength salted
   in salted == saltPass' salt clear
  where
    clear = TS.unpack clear'
    salted = TS.unpack salted'

-- | Session variable set when user logged in via a login link. See
-- 'needOldPassword'.
--
-- @since 1.2.1
loginLinkKey :: Text
loginLinkKey = "_AUTH_EMAIL_LOGIN_LINK"

-- | Set 'loginLinkKey' to the current time.
--
-- @since 1.2.1
--setLoginLinkKey :: (MonadHandler m) => AuthId site -> m ()
setLoginLinkKey :: (MonadHandler m, YesodAuthEmail (HandlerSite m)) => AuthId (HandlerSite m) -> m ()
setLoginLinkKey aid = do
  now <- liftIO getCurrentTime
  setSession loginLinkKey $ TS.pack $ show (toPathPiece aid, now)

-- See https://github.com/yesodweb/yesod/issues/1245 for discussion on this
-- use of unsafePerformIO.
defaultNonceGen :: Nonce.Generator
defaultNonceGen = unsafePerformIO Nonce.new

{-# NOINLINE defaultNonceGen #-}
