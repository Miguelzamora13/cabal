{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.Haddock
-- Copyright   :  Isaac Jones 2003-2005
-- License     :  BSD3
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This module deals with the @haddock@ and @hscolour@ commands.
-- It uses information about installed packages (from @ghc-pkg@) to find the
-- locations of documentation for dependent packages, so it can create links.
--
-- The @hscolour@ support allows generating HTML versions of the original
-- source, with coloured syntax highlighting.

module Distribution.Simple.Haddock (
  haddock, createHaddockIndex, hscolour,

  haddockPackagePaths,
  Visibility(..)
  ) where

import Prelude ()
import Distribution.Compat.Prelude

import qualified Distribution.Simple.GHC   as GHC
import qualified Distribution.Simple.GHCJS as GHCJS

-- local
import Distribution.Backpack.DescribeUnitId
import Distribution.Backpack (OpenModule)
import Distribution.Types.ForeignLib
import Distribution.Types.UnqualComponentName
import Distribution.Types.ComponentLocalBuildInfo
import Distribution.Types.ExecutableScope
import Distribution.Types.LocalBuildInfo
import Distribution.Types.TargetInfo
import Distribution.Types.ExposedModule
import Distribution.Package
import qualified Distribution.ModuleName as ModuleName
import Distribution.PackageDescription
import Distribution.Simple.Compiler
import Distribution.Simple.Glob
import Distribution.Simple.Program.GHC
import Distribution.Simple.Program.ResponseFile
import Distribution.Simple.Program
import Distribution.Simple.PreProcess
import Distribution.Simple.Flag
import Distribution.Simple.Setup.Haddock
import Distribution.Simple.Setup.Hscolour
import Distribution.Simple.Build
import Distribution.Simple.BuildTarget
import Distribution.Simple.InstallDirs
import Distribution.Simple.LocalBuildInfo hiding (substPathTemplate)
import Distribution.Simple.BuildPaths
import Distribution.Simple.Register
import qualified Distribution.Simple.Program.HcPkg as HcPkg
import qualified Distribution.Simple.PackageIndex as PackageIndex
import qualified Distribution.InstalledPackageInfo as InstalledPackageInfo
import Distribution.InstalledPackageInfo ( InstalledPackageInfo )
import Distribution.Simple.Utils
import Distribution.System
import Distribution.Pretty
import Distribution.Parsec (simpleParsec)
import Distribution.Utils.NubList
import Distribution.Version
import qualified Distribution.Utils.ShortText as ShortText

import Distribution.Verbosity
import Language.Haskell.Extension

import Distribution.Compat.Semigroup (All (..), Any (..))

import Control.Monad
import Data.Either      ( rights )

import System.Directory (getCurrentDirectory, doesDirectoryExist, doesFileExist)
import System.FilePath  ( (</>), (<.>), normalise, isAbsolute )
import System.IO        (hClose, hPutStrLn, hSetEncoding, utf8)

-- ------------------------------------------------------------------------------
-- Types

-- | A record that represents the arguments to the haddock executable, a product
-- monoid.
data HaddockArgs = HaddockArgs {
 argInterfaceFile :: Flag FilePath,
 -- ^ Path to the interface file, relative to argOutputDir, required.
 argPackageName :: Flag PackageIdentifier,
 -- ^ Package name, required.
 argHideModules :: (All,[ModuleName.ModuleName]),
 -- ^ (Hide modules ?, modules to hide)
 argIgnoreExports :: Any,
 -- ^ Ignore export lists in modules?
 argLinkSource :: Flag (Template,Template,Template),
 -- ^ (Template for modules, template for symbols, template for lines).
 argLinkedSource :: Flag Bool,
 -- ^ Generate hyperlinked sources
 argQuickJump :: Flag Bool,
 -- ^ Generate quickjump index
 argCssFile :: Flag FilePath,
 -- ^ Optional custom CSS file.
 argContents :: Flag String,
 -- ^ Optional URL to contents page.
 argGenContents :: Flag Bool,
 -- ^ Generate contents
 argIndex :: Flag String,
 -- ^ Optional URL to index page.
 argGenIndex :: Flag Bool,
 -- ^ Generate index
 argBaseUrl :: Flag String,
 -- ^ Optional base url from which static files will be loaded.
 argVerbose :: Any,
 argOutput :: Flag [Output],
 -- ^ HTML or Hoogle doc or both? Required.
 argInterfaces :: [(FilePath, Maybe String, Maybe String, Visibility)],
 -- ^ [(Interface file, URL to the HTML docs and hyperlinked-source for links)].
 argOutputDir :: Directory,
 -- ^ Where to generate the documentation.
 argTitle :: Flag String,
 -- ^ Page title, required.
 argPrologue :: Flag String,
 -- ^ Prologue text, required for 'haddock', ignored by 'haddocks'.
 argPrologueFile :: Flag FilePath,
 -- ^ Prologue file name, ignored by 'haddock', optional for 'haddocks'.
 argGhcOptions :: GhcOptions,
 -- ^ Additional flags to pass to GHC.
 argGhcLibDir :: Flag FilePath,
 -- ^ To find the correct GHC, required.
 argReexports :: [OpenModule],
 -- ^ Re-exported modules
 argTargets :: [FilePath],
 -- ^ Modules to process.
 argLib :: Flag String
 -- ^ haddock's static \/ auxiliary files.
} deriving Generic

-- | The FilePath of a directory, it's a monoid under '(</>)'.
newtype Directory = Dir { unDir' :: FilePath } deriving (Read,Show,Eq,Ord)

unDir :: Directory -> FilePath
unDir = normalise . unDir'

type Template = String

data Output = Html | Hoogle
  deriving Eq

-- ------------------------------------------------------------------------------
-- Haddock support

-- | Get Haddock program and check if it matches the request
getHaddockProg :: Verbosity
               -> ProgramDb
               -> Compiler
               -> HaddockArgs
               -> Flag Bool -- ^ quickjump feature
               -> IO (ConfiguredProgram, Version)
getHaddockProg verbosity programDb comp args quickJumpFlag = do
    let HaddockArgs { argQuickJump
                    , argOutput
                    } = args
        hoogle = Hoogle `elem` fromFlagOrDefault [] argOutput

    (haddockProg, version, _) <-
      requireProgramVersion verbosity haddockProgram
        (orLaterVersion (mkVersion [2,0])) programDb

    -- various sanity checks
    when (hoogle && version < mkVersion [2,2]) $
      die' verbosity "Haddock 2.0 and 2.1 do not support the --hoogle flag."

    when (fromFlag argQuickJump && version < mkVersion [2,19]) $ do
      let msg = "Haddock prior to 2.19 does not support the --quickjump flag."
          alt = "The generated documentation won't have the QuickJump feature."
      if Flag True == quickJumpFlag
        then die' verbosity msg
        else warn verbosity (msg ++ "\n" ++ alt)

    haddockGhcVersionStr <- getProgramOutput verbosity haddockProg
                              ["--ghc-version"]
    case (simpleParsec haddockGhcVersionStr, compilerCompatVersion GHC comp) of
      (Nothing, _) -> die' verbosity "Could not get GHC version from Haddock"
      (_, Nothing) -> die' verbosity "Could not get GHC version from compiler"
      (Just haddockGhcVersion, Just ghcVersion)
        | haddockGhcVersion == ghcVersion -> return ()
        | otherwise -> die' verbosity $
               "Haddock's internal GHC version must match the configured "
            ++ "GHC version.\n"
            ++ "The GHC version is " ++ prettyShow ghcVersion ++ " but "
            ++ "haddock is using GHC version " ++ prettyShow haddockGhcVersion

    return (haddockProg, version)


haddock :: PackageDescription
        -> LocalBuildInfo
        -> [PPSuffixHandler]
        -> HaddockFlags
        -> IO ()
haddock pkg_descr _ _ haddockFlags
  |    not (hasLibs pkg_descr)
    && not (fromFlag $ haddockExecutables haddockFlags)
    && not (fromFlag $ haddockTestSuites  haddockFlags)
    && not (fromFlag $ haddockBenchmarks  haddockFlags)
    && not (fromFlag $ haddockForeignLibs haddockFlags)
    =
      warn (fromFlag $ haddockVerbosity haddockFlags) $
           "No documentation was generated as this package does not contain "
        ++ "a library. Perhaps you want to use the --executables, --tests,"
        ++ " --benchmarks or --foreign-libraries flags."

haddock pkg_descr lbi suffixes flags' = do
    let verbosity     = flag haddockVerbosity
        comp          = compiler lbi
        platform      = hostPlatform lbi

        quickJmpFlag  = haddockQuickJump flags'
        flags = case haddockTarget of
          ForDevelopment -> flags'
          ForHackage -> flags'
            { haddockHoogle       = Flag True
            , haddockHtml         = Flag True
            , haddockHtmlLocation = Flag (pkg_url ++ "/docs")
            , haddockContents     = Flag (toPathTemplate pkg_url)
            , haddockLinkedSource = Flag True
            , haddockQuickJump    = Flag True
            }
        pkg_url       = "/package/$pkg-$version"
        flag f        = fromFlag $ f flags

        tmpFileOpts   = defaultTempFileOptions
                       { optKeepTempFiles = flag haddockKeepTempFiles }
        htmlTemplate  = fmap toPathTemplate . flagToMaybe . haddockHtmlLocation
                        $ flags
        haddockTarget =
          fromFlagOrDefault ForDevelopment (haddockForHackage flags')

    libdirArgs <- getGhcLibDir  verbosity lbi
    -- The haddock-output-dir flag overrides any other documentation placement concerns.
    -- The point is to give the user full freedom over the location if they need it.
    let overrideWithOutputDir args = case haddockOutputDir flags of
          NoFlag -> args
          Flag dir -> args { argOutputDir = Dir dir }
    let commonArgs = overrideWithOutputDir $ mconcat
            [ libdirArgs
            , fromFlags (haddockTemplateEnv lbi (packageId pkg_descr)) flags
            , fromPackageDescription haddockTarget pkg_descr ]

    (haddockProg, version) <-
      getHaddockProg verbosity (withPrograms lbi) comp commonArgs quickJmpFlag

    -- We fall back to using HsColour only for versions of Haddock which don't
    -- support '--hyperlinked-sources'.
    when (flag haddockLinkedSource && version < mkVersion [2,17]) $
      hscolour' (warn verbosity) haddockTarget pkg_descr lbi suffixes
      (defaultHscolourFlags `mappend` haddockToHscolour flags)

    targets <- readTargetInfos verbosity pkg_descr lbi (haddockArgs flags)

    let
      targets' =
        case targets of
          [] -> allTargetsInBuildOrder' pkg_descr lbi
          _  -> targets

    internalPackageDB <-
      createInternalPackageDB verbosity lbi (flag haddockDistPref)

    (\f -> foldM_ f (installedPkgs lbi) targets') $ \index target -> do

      let component = targetComponent target
          clbi      = targetCLBI target

      componentInitialBuildSteps (flag haddockDistPref) pkg_descr lbi clbi verbosity

      let
        lbi' = lbi {
          withPackageDB = withPackageDB lbi ++ [internalPackageDB],
          installedPkgs = index
          }

      preprocessComponent pkg_descr component lbi' clbi False verbosity suffixes
      let
        doExe com = case (compToExe com) of
          Just exe -> do
            withTempDirectoryEx verbosity tmpFileOpts (buildDir lbi') "tmp" $
              \tmp -> do
                exeArgs <- fromExecutable verbosity tmp lbi' clbi htmlTemplate
                             version exe
                let exeArgs' = commonArgs `mappend` exeArgs
                runHaddock verbosity tmpFileOpts comp platform
                  haddockProg True exeArgs'
          Nothing -> do
           warn (fromFlag $ haddockVerbosity flags)
             "Unsupported component, skipping..."
           return ()
        -- We define 'smsg' once and then reuse it inside the case, so that
        -- we don't say we are running Haddock when we actually aren't
        -- (e.g., Haddock is not run on non-libraries)
        smsg :: IO ()
        smsg = setupMessage' verbosity "Running Haddock on" (packageId pkg_descr)
                (componentLocalName clbi) (maybeComponentInstantiatedWith clbi)
      case component of
        CLib lib -> do
          withTempDirectoryEx verbosity tmpFileOpts (buildDir lbi) "tmp" $
            \tmp -> do
              smsg
              libArgs <- fromLibrary verbosity tmp lbi' clbi htmlTemplate
                           version lib
              let libArgs' = commonArgs `mappend` libArgs
              runHaddock verbosity tmpFileOpts comp platform haddockProg True libArgs'

              pwd <- getCurrentDirectory

              let
                ipi = inplaceInstalledPackageInfo
                        pwd (flag haddockDistPref) pkg_descr
                        (mkAbiHash "inplace") lib lbi' clbi

              debug verbosity $ "Registering inplace:\n"
                ++ (InstalledPackageInfo.showInstalledPackageInfo ipi)

              registerPackage verbosity (compiler lbi') (withPrograms lbi')
                (withPackageDB lbi') ipi
                HcPkg.defaultRegisterOptions {
                  HcPkg.registerMultiInstance = True
                }

              return $ PackageIndex.insert ipi index

        CFLib flib -> (when (flag haddockForeignLibs) $ do
          withTempDirectoryEx verbosity tmpFileOpts (buildDir lbi') "tmp" $
            \tmp -> do
              smsg
              flibArgs <- fromForeignLib verbosity tmp lbi' clbi htmlTemplate
                            version flib
              let libArgs' = commonArgs `mappend` flibArgs
              runHaddock verbosity tmpFileOpts comp platform haddockProg True libArgs')

          >> return index

        CExe   _ -> (when (flag haddockExecutables) $ smsg >> doExe component) >> return index
        CTest  _ -> (when (flag haddockTestSuites)  $ smsg >> doExe component) >> return index
        CBench _ -> (when (flag haddockBenchmarks)  $ smsg >> doExe component) >> return index

    for_ (extraDocFiles pkg_descr) $ \ fpath -> do
      files <- matchDirFileGlob verbosity (specVersion pkg_descr) "." fpath
      for_ files $ copyFileTo verbosity (unDir $ argOutputDir commonArgs)


-- | Execute 'Haddock' configured with 'HaddocksFlags'.  It is used to build
-- index and contents for documentation of multiple packages.
--
createHaddockIndex :: Verbosity
                   -> ProgramDb
                   -> Compiler
                   -> Platform
                   -> HaddockProjectFlags
                   -> IO ()
createHaddockIndex verbosity programDb comp platform flags = do
    let args = fromHaddockProjectFlags flags
    (haddockProg, _version) <-
      getHaddockProg verbosity programDb comp args (haddockProjectQuickJump flags)
    runHaddock verbosity defaultTempFileOptions comp platform haddockProg False args

-- ------------------------------------------------------------------------------
-- Contributions to HaddockArgs (see also Doctest.hs for very similar code).

fromFlags :: PathTemplateEnv -> HaddockFlags -> HaddockArgs
fromFlags env flags =
    mempty {
      argHideModules = (maybe mempty (All . not)
                        $ flagToMaybe (haddockInternal flags), mempty),
      argLinkSource = if fromFlag (haddockLinkedSource flags)
                               then Flag ("src/%{MODULE/./-}.html"
                                         ,"src/%{MODULE/./-}.html#%{NAME}"
                                         ,"src/%{MODULE/./-}.html#line-%{LINE}")
                               else NoFlag,
      argLinkedSource = haddockLinkedSource flags,
      argQuickJump = haddockQuickJump flags,
      argCssFile = haddockCss flags,
      argContents = fmap (fromPathTemplate . substPathTemplate env)
                    (haddockContents flags),
      argGenContents = Flag False,
      argIndex = fmap (fromPathTemplate . substPathTemplate env)
                    (haddockIndex flags),
      argGenIndex = Flag False,
      argBaseUrl = haddockBaseUrl flags,
      argLib = haddockLib flags,
      argVerbose = maybe mempty (Any . (>= deafening))
                   . flagToMaybe $ haddockVerbosity flags,
      argOutput =
          Flag $ case [ Html | Flag True <- [haddockHtml flags] ] ++
                      [ Hoogle | Flag True <- [haddockHoogle flags] ]
                 of [] -> [ Html ]
                    os -> os,
      argOutputDir = maybe mempty Dir . flagToMaybe $ haddockDistPref flags,

      argGhcOptions = mempty { ghcOptExtra = ghcArgs }
    }
    where
      ghcArgs = fromMaybe [] . lookup "ghc" . haddockProgramArgs $ flags

fromHaddockProjectFlags :: HaddockProjectFlags -> HaddockArgs
fromHaddockProjectFlags flags =
    mempty
      { argOutputDir = Dir (fromFlag $ haddockProjectDir flags)
      , argQuickJump = haddockProjectQuickJump flags
      , argGenContents = haddockProjectGenContents flags
      , argGenIndex = haddockProjectGenIndex flags
      , argPrologueFile = haddockProjectPrologue flags
      , argInterfaces = fromFlagOrDefault [] (haddockProjectInterfaces flags)
      , argLinkedSource = haddockProjectLinkedSource flags
      , argLib = haddockProjectLib flags
      }


fromPackageDescription :: HaddockTarget -> PackageDescription -> HaddockArgs
fromPackageDescription haddockTarget pkg_descr = mempty
    { argInterfaceFile = Flag $ haddockName pkg_descr
    , argPackageName = Flag $ packageId $ pkg_descr
    , argOutputDir = Dir $
        "doc" </> "html" </> haddockDirName haddockTarget pkg_descr
    , argPrologue = Flag $ ShortText.fromShortText $
        if ShortText.null desc
        then synopsis pkg_descr
        else desc
    , argTitle = Flag $ showPkg ++ subtitle
    }
  where
    desc = description pkg_descr
    showPkg = prettyShow (packageId pkg_descr)
    subtitle
        | ShortText.null (synopsis pkg_descr) = ""
        | otherwise                           = ": " ++ ShortText.fromShortText (synopsis pkg_descr)

componentGhcOptions :: Verbosity -> LocalBuildInfo
                 -> BuildInfo -> ComponentLocalBuildInfo -> FilePath
                 -> GhcOptions
componentGhcOptions verbosity lbi bi clbi odir =
  let f = case compilerFlavor (compiler lbi) of
            GHC   -> GHC.componentGhcOptions
            GHCJS -> GHCJS.componentGhcOptions
            _     -> error $
                       "Distribution.Simple.Haddock.componentGhcOptions:" ++
                       "haddock only supports GHC and GHCJS"
  in f verbosity lbi bi clbi odir

mkHaddockArgs :: Verbosity
              -> FilePath
              -> LocalBuildInfo
              -> ComponentLocalBuildInfo
              -> Maybe PathTemplate -- ^ template for HTML location
              -> Version
              -> [FilePath]
              -> BuildInfo
              -> IO HaddockArgs
mkHaddockArgs verbosity tmp lbi clbi htmlTemplate haddockVersion inFiles bi = do
    ifaceArgs <- getInterfaces verbosity lbi clbi htmlTemplate
    let vanillaOpts = (componentGhcOptions normal lbi bi clbi (buildDir lbi)) {
                          -- Noooooooooo!!!!!111
                          -- haddock stomps on our precious .hi
                          -- and .o files. Workaround by telling
                          -- haddock to write them elsewhere.
                          ghcOptObjDir     = toFlag tmp,
                          ghcOptHiDir      = toFlag tmp,
                          ghcOptStubDir    = toFlag tmp
                      } `mappend` getGhcCppOpts haddockVersion bi
        sharedOpts = vanillaOpts {
                         ghcOptDynLinkMode = toFlag GhcDynamicOnly,
                         ghcOptFPic        = toFlag True,
                         ghcOptHiSuffix    = toFlag "dyn_hi",
                         ghcOptObjSuffix   = toFlag "dyn_o",
                         ghcOptExtra       = hcSharedOptions GHC bi

                     }
    opts <- if withVanillaLib lbi
            then return vanillaOpts
            else if withSharedLib lbi
            then return sharedOpts
            else die' verbosity $ "Must have vanilla or shared libraries "
                       ++ "enabled in order to run haddock"

    return ifaceArgs
      { argGhcOptions  = opts
      , argTargets     = inFiles
      , argReexports   = getReexports clbi
      }

fromLibrary :: Verbosity
            -> FilePath
            -> LocalBuildInfo
            -> ComponentLocalBuildInfo
            -> Maybe PathTemplate -- ^ template for HTML location
            -> Version
            -> Library
            -> IO HaddockArgs
fromLibrary verbosity tmp lbi clbi htmlTemplate haddockVersion lib = do
    inFiles <- map snd `fmap` getLibSourceFiles verbosity lbi lib clbi
    args    <- mkHaddockArgs verbosity tmp lbi clbi htmlTemplate haddockVersion
                 inFiles (libBuildInfo lib)
    return args {
      argHideModules = (mempty, otherModules (libBuildInfo lib))
    }

fromExecutable :: Verbosity
               -> FilePath
               -> LocalBuildInfo
               -> ComponentLocalBuildInfo
               -> Maybe PathTemplate -- ^ template for HTML location
               -> Version
               -> Executable
               -> IO HaddockArgs
fromExecutable verbosity tmp lbi clbi htmlTemplate haddockVersion exe = do
    inFiles <- map snd `fmap` getExeSourceFiles verbosity lbi exe clbi
    args    <- mkHaddockArgs verbosity tmp lbi clbi htmlTemplate
                 haddockVersion inFiles (buildInfo exe)
    return args {
      argOutputDir  = Dir  $ unUnqualComponentName $ exeName exe,
      argTitle      = Flag $ unUnqualComponentName $ exeName exe
    }

fromForeignLib :: Verbosity
               -> FilePath
               -> LocalBuildInfo
               -> ComponentLocalBuildInfo
               -> Maybe PathTemplate -- ^ template for HTML location
               -> Version
               -> ForeignLib
               -> IO HaddockArgs
fromForeignLib verbosity tmp lbi clbi htmlTemplate haddockVersion flib = do
    inFiles <- map snd `fmap` getFLibSourceFiles verbosity lbi flib clbi
    args    <- mkHaddockArgs verbosity tmp lbi clbi htmlTemplate
                 haddockVersion inFiles (foreignLibBuildInfo flib)
    return args {
      argOutputDir  = Dir  $ unUnqualComponentName $ foreignLibName flib,
      argTitle      = Flag $ unUnqualComponentName $ foreignLibName flib
    }

compToExe :: Component -> Maybe Executable
compToExe comp =
  case comp of
    CTest test@TestSuite { testInterface = TestSuiteExeV10 _ f } ->
      Just Executable {
        exeName    = testName test,
        modulePath = f,
        exeScope   = ExecutablePublic,
        buildInfo  = testBuildInfo test
      }
    CBench bench@Benchmark { benchmarkInterface = BenchmarkExeV10 _ f } ->
      Just Executable {
        exeName    = benchmarkName bench,
        modulePath = f,
        exeScope   = ExecutablePublic,
        buildInfo  = benchmarkBuildInfo bench
      }
    CExe exe -> Just exe
    _ -> Nothing

getInterfaces :: Verbosity
              -> LocalBuildInfo
              -> ComponentLocalBuildInfo
              -> Maybe PathTemplate -- ^ template for HTML location
              -> IO HaddockArgs
getInterfaces verbosity lbi clbi htmlTemplate = do
    (packageFlags, warnings) <- haddockPackageFlags verbosity lbi clbi htmlTemplate
    traverse_ (warn (verboseUnmarkOutput verbosity)) warnings
    return $ mempty {
                 argInterfaces = packageFlags
               }

getReexports :: ComponentLocalBuildInfo -> [OpenModule]
getReexports LibComponentLocalBuildInfo {componentExposedModules = mods } =
    mapMaybe exposedReexport mods
getReexports _ = []

getGhcCppOpts :: Version
              -> BuildInfo
              -> GhcOptions
getGhcCppOpts haddockVersion bi =
    mempty {
        ghcOptExtensions   = toNubListR [EnableExtension CPP | needsCpp],
        ghcOptCppOptions   = defines
    }
  where
    needsCpp             = EnableExtension CPP `elem` usedExtensions bi
    defines              = [haddockVersionMacro]
    haddockVersionMacro  = "-D__HADDOCK_VERSION__="
                           ++ show (v1 * 1000 + v2 * 10 + v3)
      where
        (v1, v2, v3) = case versionNumbers haddockVersion of
            []        -> (0,0,0)
            [x]       -> (x,0,0)
            [x,y]     -> (x,y,0)
            (x:y:z:_) -> (x,y,z)

getGhcLibDir :: Verbosity -> LocalBuildInfo
             -> IO HaddockArgs
getGhcLibDir verbosity lbi = do
    l <- case compilerFlavor (compiler lbi) of
            GHC   -> GHC.getLibDir   verbosity lbi
            GHCJS -> GHCJS.getLibDir verbosity lbi
            _     -> error "haddock only supports GHC and GHCJS"
    return $ mempty { argGhcLibDir = Flag l }

-- ------------------------------------------------------------------------------
-- | Call haddock with the specified arguments.
runHaddock :: Verbosity
              -> TempFileOptions
              -> Compiler
              -> Platform
              -> ConfiguredProgram
              -> Bool -- ^ require targets
              -> HaddockArgs
              -> IO ()
runHaddock verbosity tmpFileOpts comp platform haddockProg requireTargets args
  | requireTargets && null (argTargets args) = warn verbosity $
       "Haddocks are being requested, but there aren't any modules given "
    ++ "to create documentation for."
  | otherwise = do
    let haddockVersion = fromMaybe (error "unable to determine haddock version")
                        (programVersion haddockProg)
    renderArgs verbosity tmpFileOpts haddockVersion comp platform args $
      \(flags,result)-> do

        runProgram verbosity haddockProg flags

        notice verbosity $ "Documentation created: " ++ result


renderArgs :: Verbosity
              -> TempFileOptions
              -> Version
              -> Compiler
              -> Platform
              -> HaddockArgs
              -> (([String], FilePath) -> IO a)
              -> IO a
renderArgs verbosity tmpFileOpts version comp platform args k = do
  let haddockSupportsUTF8          = version >= mkVersion [2,14,4]
      haddockSupportsResponseFiles = version >  mkVersion [2,16,2]
  createDirectoryIfMissingVerbose verbosity True outputDir
  case argPrologue args of
    Flag prologueText ->
      withTempFileEx tmpFileOpts outputDir "haddock-prologue.txt" $
        \prologueFileName h -> do
              do
                 when haddockSupportsUTF8 (hSetEncoding h utf8)
                 hPutStrLn h prologueText
                 hClose h
                 let pflag = "--prologue=" ++ prologueFileName
                     renderedArgs = pflag : renderPureArgs version comp platform args
                 if haddockSupportsResponseFiles
                   then
                     withResponseFile
                       verbosity
                       tmpFileOpts
                       outputDir
                       "haddock-response.txt"
                       (if haddockSupportsUTF8 then Just utf8 else Nothing)
                       renderedArgs
                       (\responseFileName -> k (["@" ++ responseFileName], result))
                   else
                     k (renderedArgs, result)
    _ -> do
      let renderedArgs = (case argPrologueFile args of
                            Flag pfile -> ["--prologue="++pfile]
                            _          -> [])
                      <> renderPureArgs version comp platform args
      if haddockSupportsResponseFiles
        then
          withResponseFile
            verbosity
            tmpFileOpts
            outputDir
            "haddock-response.txt"
            (if haddockSupportsUTF8 then Just utf8 else Nothing)
            renderedArgs
            (\responseFileName -> k (["@" ++ responseFileName], result))
        else
          k (renderedArgs, result)
    where
      outputDir = (unDir $ argOutputDir args)
      result = intercalate ", "
             . map (\o -> outputDir </>
                            case o of
                              Html -> "index.html"
                              Hoogle -> pkgstr <.> "txt")
             . fromFlagOrDefault [Html]
             . argOutput
             $ args
            where
              pkgstr = prettyShow $ packageName pkgid
              pkgid = arg argPackageName
      arg f = fromFlag $ f args

renderPureArgs :: Version -> Compiler -> Platform -> HaddockArgs -> [String]
renderPureArgs version comp platform args = concat
    [ map (\f -> "--dump-interface="++ unDir (argOutputDir args) </> f)
      . flagToList . argInterfaceFile $ args

    , if haddockSupportsPackageName
        then maybe [] (\pkg -> [ "--package-name=" ++ prettyShow (pkgName pkg)
                               , "--package-version=" ++ prettyShow (pkgVersion pkg)
                               ])
             . flagToMaybe . argPackageName $ args
        else []

    , [ "--since-qual=external" | isVersion 2 20 ]

    , [ "--quickjump" | isVersion 2 19
                      , _ <- flagToList . argQuickJump $ args ]

    , [ "--hyperlinked-source" | isVersion 2 17
                               , True <- flagToList . argLinkedSource $ args ]

    , (\(All b,xs) -> bool (map (("--hide=" ++) . prettyShow) xs) [] b)
                     . argHideModules $ args

    , bool ["--ignore-all-exports"] [] . getAny . argIgnoreExports $ args

    , maybe [] (\(m,e,l) ->
                 ["--source-module=" ++ m
                 ,"--source-entity=" ++ e]
                 ++ if isVersion 2 14 then ["--source-entity-line=" ++ l]
                    else []
               ) . flagToMaybe . argLinkSource $ args

    , maybe [] ((:[]) . ("--css="++)) . flagToMaybe . argCssFile $ args

    , maybe [] ((:[]) . ("--use-contents="++)) . flagToMaybe . argContents $ args

    , bool ["--gen-contents"] [] .fromFlagOrDefault False . argGenContents $ args

    , maybe [] ((:[]) . ("--use-index="++)) . flagToMaybe . argIndex $ args

    , bool ["--gen-index"] [] . fromFlagOrDefault False . argGenIndex $ args

    , maybe [] ((:[]) . ("--base-url="++)) . flagToMaybe . argBaseUrl $ args

    , bool [] [verbosityFlag] . getAny . argVerbose $ args

    , map (\o -> case o of Hoogle -> "--hoogle"; Html -> "--html")
      . fromFlagOrDefault [] . argOutput $ args

    , renderInterfaces . argInterfaces $ args

    , (:[]) . ("--odir="++) . unDir . argOutputDir $ args

    , maybe []
        ( (:[])
        . ("--title="++)
        . (bool (++" (internal documentation)")
                id (getAny $ argIgnoreExports args))
        )
        . flagToMaybe . argTitle $ args

    , [ "--optghc=" ++ opt | let opts = argGhcOptions args
                           , opt <- renderGhcOptions comp platform opts ]

    , maybe [] (\l -> ["-B"++l]) $
      flagToMaybe (argGhcLibDir args) -- error if Nothing?

      -- https://github.com/haskell/haddock/pull/547
    , [ "--reexport=" ++ prettyShow r
      | r <- argReexports args
      , isVersion 2 19
      ]

    , argTargets $ args
    , maybe [] ((:[]) . ("--lib="++)) . flagToMaybe . argLib $ args
    ]
    where
      renderInterfaces = map renderInterface

      renderInterface :: (FilePath, Maybe FilePath, Maybe FilePath, Visibility) -> String
      renderInterface (i, html, hypsrc, visibility) = "--read-interface=" ++
        (intercalate "," $ concat [ [ fromMaybe "" html ]
                                  , -- only render hypsrc path if html path
                                    -- is given and hyperlinked-source is
                                    -- enabled
                                    [ case (html, hypsrc) of
                                        (Nothing, _) -> ""
                                        (_, Nothing) -> ""
                                        (_, Just x)  | isVersion 2 17
                                                     , fromFlagOrDefault False . argLinkedSource $ args
                                                     -> x
                                                     | otherwise
                                                     -> ""
                                    ]
                                  , if haddockSupportsVisibility
                                      then [ case visibility of
                                               Visible -> "visible"
                                               Hidden  -> "hidden"
                                           ]
                                      else []
                                  , [ i ]
                                  ])

      bool a b c = if c then a else b
      isVersion major minor  = version >= mkVersion [major,minor]
      verbosityFlag
       | isVersion 2 5 = "--verbosity=1"
       | otherwise     = "--verbose"
      haddockSupportsVisibility = version >= mkVersion [2,26,1]
      haddockSupportsPackageName = version > mkVersion [2,16]

---------------------------------------------------------------------------------

-- | Given a list of 'InstalledPackageInfo's, return a list of interfaces and
-- HTML paths, and an optional warning for packages with missing documentation.
haddockPackagePaths :: [InstalledPackageInfo]
                    -> Maybe (InstalledPackageInfo -> FilePath)
                    -> IO ([( FilePath        -- path to interface
                                                         -- file

                                       , Maybe FilePath  -- url to html
                                                         -- documentation

                                       , Maybe FilePath  -- url to hyperlinked
                                                         -- source
                                       , Visibility
                                       )]
                                     , Maybe String      -- warning about
                                                         -- missing documentation
                                     )
haddockPackagePaths ipkgs mkHtmlPath = do
  interfaces <- sequenceA
    [ case interfaceAndHtmlPath ipkg of
        Nothing -> return (Left (packageId ipkg))
        Just (interface, html) -> do

          (html', hypsrc') <-
            case html of
              Just htmlPath -> do
                let hypSrcPath = htmlPath </> defaultHyperlinkedSourceDirectory
                hypSrcExists <- doesDirectoryExist hypSrcPath
                return $ ( Just (fixFileUrl htmlPath)
                         , if hypSrcExists
                           then Just (fixFileUrl hypSrcPath)
                           else Nothing
                         )
              Nothing -> return (Nothing, Nothing)

          exists <- doesFileExist interface
          if exists
            then return (Right (interface, html', hypsrc', Visible))
            else return (Left pkgid)
    | ipkg <- ipkgs, let pkgid = packageId ipkg
    , pkgName pkgid `notElem` noHaddockWhitelist
    ]

  let missing = [ pkgid | Left pkgid <- interfaces ]
      warning = "The documentation for the following packages are not "
             ++ "installed. No links will be generated to these packages: "
             ++ intercalate ", " (map prettyShow missing)
      flags = rights interfaces

  return (flags, if null missing then Nothing else Just warning)

  where
    -- Don't warn about missing documentation for these packages. See #1231.
    noHaddockWhitelist = map mkPackageName [ "rts" ]

    -- Actually extract interface and HTML paths from an 'InstalledPackageInfo'.
    interfaceAndHtmlPath :: InstalledPackageInfo
                         -> Maybe (FilePath, Maybe FilePath)
    interfaceAndHtmlPath pkg = do
      interface <- listToMaybe (InstalledPackageInfo.haddockInterfaces pkg)
      html <- case mkHtmlPath of
        Nothing     -> listToMaybe (InstalledPackageInfo.haddockHTMLs pkg)
        Just mkPath -> Just (mkPath pkg)
      return (interface, if null html then Nothing else Just html)

    -- The 'haddock-html' field in the hc-pkg output is often set as a
    -- native path, but we need it as a URL. See #1064. Also don't "fix"
    -- the path if it is an interpolated one.
    fixFileUrl f | Nothing <- mkHtmlPath
                 , isAbsolute f = "file://" ++ f
                 | otherwise    = f

    -- 'src' is the default hyperlinked source directory ever since. It is
    -- not possible to configure that directory in any way in haddock.
    defaultHyperlinkedSourceDirectory = "src"


haddockPackageFlags :: Verbosity
                    -> LocalBuildInfo
                    -> ComponentLocalBuildInfo
                    -> Maybe PathTemplate
                    -> IO ([( FilePath        -- path to interface
                                              -- file

                            , Maybe FilePath  -- url to html
                                              -- documentation

                            , Maybe FilePath  -- url to hyperlinked
                                              -- source
                            , Visibility
                            )]
                          , Maybe String      -- warning about
                                              -- missing documentation
                          )
haddockPackageFlags verbosity lbi clbi htmlTemplate = do
  let allPkgs = installedPkgs lbi
      directDeps = map fst (componentPackageDeps clbi)
  transitiveDeps <- case PackageIndex.dependencyClosure allPkgs directDeps of
    Left x    -> return x
    Right inf -> die' verbosity $ "internal error when calculating transitive "
                    ++ "package dependencies.\nDebug info: " ++ show inf
  haddockPackagePaths (PackageIndex.allPackages transitiveDeps) mkHtmlPath
    where
      mkHtmlPath                  = fmap expandTemplateVars htmlTemplate
      expandTemplateVars tmpl pkg =
        fromPathTemplate . substPathTemplate (env pkg) $ tmpl
      env pkg                     = haddockTemplateEnv lbi (packageId pkg)


haddockTemplateEnv :: LocalBuildInfo -> PackageIdentifier -> PathTemplateEnv
haddockTemplateEnv lbi pkg_id =
  (PrefixVar, prefix (installDirTemplates lbi))
  -- We want the legacy unit ID here, because it gives us nice paths
  -- (Haddock people don't care about the dependencies)
  : initialPathTemplateEnv
      pkg_id
      (mkLegacyUnitId pkg_id)
      (compilerInfo (compiler lbi))
      (hostPlatform lbi)

-- ------------------------------------------------------------------------------
-- hscolour support.

hscolour :: PackageDescription
         -> LocalBuildInfo
         -> [PPSuffixHandler]
         -> HscolourFlags
         -> IO ()
hscolour = hscolour' dieNoVerbosity ForDevelopment

hscolour' :: (String -> IO ()) -- ^ Called when the 'hscolour' exe is not found.
          -> HaddockTarget
          -> PackageDescription
          -> LocalBuildInfo
          -> [PPSuffixHandler]
          -> HscolourFlags
          -> IO ()
hscolour' onNoHsColour haddockTarget pkg_descr lbi suffixes flags =
    either onNoHsColour (\(hscolourProg, _, _) -> go hscolourProg) =<<
      lookupProgramVersion verbosity hscolourProgram
      (orLaterVersion (mkVersion [1,8])) (withPrograms lbi)
  where
    go :: ConfiguredProgram -> IO ()
    go hscolourProg = do
      warn verbosity $
        "the 'cabal hscolour' command is deprecated in favour of 'cabal " ++
        "haddock --hyperlink-source' and will be removed in the next major " ++
        "release."

      setupMessage verbosity "Running hscolour for" (packageId pkg_descr)
      createDirectoryIfMissingVerbose verbosity True $
        hscolourPref haddockTarget distPref pkg_descr

      withAllComponentsInBuildOrder pkg_descr lbi $ \comp clbi -> do
        componentInitialBuildSteps distPref pkg_descr lbi clbi verbosity
        preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
        let
          doExe com = case (compToExe com) of
            Just exe -> do
              let outputDir = hscolourPref haddockTarget distPref pkg_descr
                              </> unUnqualComponentName (exeName exe) </> "src"
              runHsColour hscolourProg outputDir =<< getExeSourceFiles verbosity lbi exe clbi
            Nothing -> do
              warn (fromFlag $ hscolourVerbosity flags)
                "Unsupported component, skipping..."
              return ()
        case comp of
          CLib lib -> do
            let outputDir = hscolourPref haddockTarget distPref pkg_descr </> "src"
            runHsColour hscolourProg outputDir =<< getLibSourceFiles verbosity lbi lib clbi
          CFLib flib -> do
            let outputDir = hscolourPref haddockTarget distPref pkg_descr
                              </> unUnqualComponentName (foreignLibName flib) </> "src"
            runHsColour hscolourProg outputDir =<< getFLibSourceFiles verbosity lbi flib clbi
          CExe   _ -> when (fromFlag (hscolourExecutables flags)) $ doExe comp
          CTest  _ -> when (fromFlag (hscolourTestSuites  flags)) $ doExe comp
          CBench _ -> when (fromFlag (hscolourBenchmarks  flags)) $ doExe comp

    stylesheet = flagToMaybe (hscolourCSS flags)

    verbosity  = fromFlag (hscolourVerbosity flags)
    distPref   = fromFlag (hscolourDistPref flags)

    runHsColour prog outputDir moduleFiles = do
         createDirectoryIfMissingVerbose verbosity True outputDir

         case stylesheet of -- copy the CSS file
           Nothing | programVersion prog >= Just (mkVersion [1,9]) ->
                       runProgram verbosity prog
                          ["-print-css", "-o" ++ outputDir </> "hscolour.css"]
                   | otherwise -> return ()
           Just s -> copyFileVerbose verbosity s (outputDir </> "hscolour.css")

         for_ moduleFiles $ \(m, inFile) ->
             runProgram verbosity prog
                    ["-css", "-anchor", "-o" ++ outFile m, inFile]
        where
          outFile m = outputDir </>
                      intercalate "-" (ModuleName.components m) <.> "html"

haddockToHscolour :: HaddockFlags -> HscolourFlags
haddockToHscolour flags =
    HscolourFlags {
      hscolourCSS         = haddockHscolourCss flags,
      hscolourExecutables = haddockExecutables flags,
      hscolourTestSuites  = haddockTestSuites  flags,
      hscolourBenchmarks  = haddockBenchmarks  flags,
      hscolourForeignLibs = haddockForeignLibs flags,
      hscolourVerbosity   = haddockVerbosity   flags,
      hscolourDistPref    = haddockDistPref    flags,
      hscolourCabalFilePath = haddockCabalFilePath flags
    }

-- ------------------------------------------------------------------------------
-- Boilerplate Monoid instance.
instance Monoid HaddockArgs where
    mempty = gmempty
    mappend = (<>)

instance Semigroup HaddockArgs where
    (<>) = gmappend

instance Monoid Directory where
    mempty = Dir "."
    mappend = (<>)

instance Semigroup Directory where
    Dir m <> Dir n = Dir $ m </> n
