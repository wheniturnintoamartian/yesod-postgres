{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Custom.Auth.EmailSpec (spec) where

import qualified Data.Text            as T
import           Database.Persist.Sql
import           TestImport

spec :: Spec
spec = withApp $

  describe "Post request to SetPasswordR" $ do

    let getCheckR = do
          TestImport.get ("http://localhost:3000/auth/check" :: Text)
          statusIs 200

    it "gives a 200 and the body contains \"message\":\"Password updated\"" $ do

      getCheckR

      userEntity <- createUser "steve.papadogiannis1992@gmail.com"
      let (Entity _id _) = userEntity

      let newPassword = "newPassword" :: Text
          confirmPassword = "newPassword" :: Text
          body = object [ "new" .= newPassword, "confirm" .= confirmPassword ]
          encoded = encode body
          userId = T.pack . show . unSqlBackendKey . unUserKey $ _id

      encryptedAndUrlEncodedUserId <- encryptAndUrlEncode userId
      encryptedAndUrlEncodedVerificationToken <- encryptAndUrlEncode "a"

      request $ do
        setMethod "POST"
        setUrl $ AuthR $ PluginR "email" ["reset-password", encryptedAndUrlEncodedUserId, encryptedAndUrlEncodedVerificationToken]
        setRequestBody encoded
        addRequestHeader ("Content-Type", "application/json")
        addTokenFromCookie

      statusIs 200

--            [Entity _id user] <- runDB $ selectList [UserVerkey ==. Just "a"] []
--            assertEq "Should have " comment (Comment message Nothing)
      bodyContains "\"message\":\"Password updated\""