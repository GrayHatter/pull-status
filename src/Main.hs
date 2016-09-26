{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import           Control.Monad           (join)
import           Control.Monad.Catch     (throwM)
import qualified Control.Monad.Parallel  as Parallel
import qualified Data.ByteString.Char8   as BS8
import qualified Data.Text               as Text
import qualified Data.Vector             as V
import qualified GitHub
import qualified GitHub.Data.Id          as GitHub
import           Network.HTTP.Client     (Manager, newManager)
import           Network.HTTP.Client.TLS (tlsManagerSettings)
import           System.Environment      (getEnv, lookupEnv)

import           PullRequestInfo         (PullRequestInfo (PullRequestInfo))
import qualified PullRequestInfo
import qualified Review


request :: GitHub.Auth -> Manager -> GitHub.Request k a -> IO a
request auth mgr req = do
  possiblePRs <- GitHub.executeRequestWithMgr mgr auth req
  case possiblePRs of
    Left  err -> throwM err
    Right res -> return res


getFullPr :: GitHub.Auth -> Manager -> GitHub.Name GitHub.Owner -> GitHub.Name GitHub.Repo -> GitHub.SimplePullRequest -> IO GitHub.PullRequest
getFullPr auth mgr owner repo simplePr = do
  putStrLn $ "getting PR info for #" ++ show (GitHub.simplePullRequestNumber simplePr)
  request auth mgr
    . GitHub.pullRequestR owner repo
    . GitHub.Id
    . GitHub.simplePullRequestNumber
    $ simplePr


getPrsForRepo
  :: GitHub.Auth
  -> Manager
  -> GitHub.Name GitHub.Owner
  -> GitHub.Name GitHub.Repo
  -> IO [PullRequestInfo]
getPrsForRepo auth mgr ownerName repoName = do
  -- Get PR list.
  putStrLn $ "getting PR list for " ++
    Text.unpack (GitHub.untagName ownerName) ++
    "/" ++
    Text.unpack (GitHub.untagName repoName)
  simplePRs <- V.toList <$> request auth mgr (GitHub.pullRequestsForR ownerName repoName GitHub.stateOpen GitHub.FetchAll)
  fullPrs <- Parallel.mapM (getFullPr auth mgr ownerName repoName) simplePRs

  -- Fetch and parse HTML pages for each PR.
  prHtmls <- Parallel.mapM (Review.fetchHtml mgr) simplePRs
  return $ zipWith (PullRequestInfo repoName . Review.approvalsFromHtml) prHtmls fullPrs


main :: IO ()
main = do
  let orgName = "TokTok"
  let ownerName = "TokTok"

  -- Get auth token from the $GITHUB_TOKEN environment variable.
  token <- BS8.pack <$> getEnv "GITHUB_TOKEN"
  let auth = GitHub.OAuth token

  -- Check if we need to produce HTML or ASCII art.
  wantHtml <- not . null <$> lookupEnv "GITHUB_WANT_HTML"

  -- Initialise HTTP manager so we can benefit from keep-alive connections.
  mgr <- newManager tlsManagerSettings

  -- Get repo list.
  putStrLn $ "getting repo list for " ++ Text.unpack (GitHub.untagName ownerName)
  repos <- V.toList <$> request auth mgr (GitHub.organizationReposR orgName GitHub.RepoPublicityAll GitHub.FetchAll)
  let repoNames = map GitHub.repoName repos

  infos <- join <$> Parallel.mapM (getPrsForRepo auth mgr ownerName) repoNames

  -- Pretty-print table with information.
  putStrLn $ PullRequestInfo.formatPR wantHtml infos
