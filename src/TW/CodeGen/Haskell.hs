{-# LANGUAGE OverloadedStrings #-}
module TW.CodeGen.Haskell
    ( makeFileName, makeModule )
where

import TW.Ast
import TW.BuiltIn
import TW.JsonRepr

import Data.Char
import Data.Maybe
import Data.Monoid
import System.FilePath
import qualified Data.List as L
import qualified Data.Text as T

aesonQual :: T.Text
aesonQual = "Data_Aeson_Lib"

aeson :: T.Text -> T.Text
aeson x = aesonQual <> "." <> x

aesonTQual :: T.Text
aesonTQual = "Data_Aeson_Types"

aesonT :: T.Text -> T.Text
aesonT x = aesonTQual <> "." <> x

makeFileName :: ModuleName -> FilePath
makeFileName (ModuleName parts) =
    (L.foldl' (</>) "" $ map T.unpack parts) ++ ".hs"

makeModule :: Module -> T.Text
makeModule m =
    T.unlines
    [ "{-# LANGUAGE OverloadedStrings #-}"
    , "-- | This file was auto generated by typed-wire. Do not modify by hand"
    , "module " <> printModuleName (m_name m) <> " where"
    , ""
    , T.intercalate "\n" (map makeImport $ m_imports m)
    , ""
    , "import Control.Applicative"
    , "import Control.Monad (join)"
    , "import qualified Data.Aeson as " <> aesonQual
    , "import qualified Data.Aeson.Types as " <> aesonTQual
    , "import qualified Data.Text as T"
    , ""
    , T.intercalate "\n" (map makeTypeDef $ m_typeDefs m)
    ]

makeImport :: ModuleName -> T.Text
makeImport m =
    "import qualified " <> printModuleName m

makeTypeDef :: TypeDef -> T.Text
makeTypeDef td =
    case td of
      TypeDefEnum ed ->
          makeEnumDef ed
      TypeDefStruct sd ->
          makeStructDef sd

makeFieldPrefix :: TypeName -> T.Text
makeFieldPrefix (TypeName name) =
    (T.toLower $ T.filter isUpper name) <> "_"

makeStructDef :: StructDef -> T.Text
makeStructDef sd =
    T.unlines
    [ "data " <> fullType
    , "   = " <> unTypeName (sd_name sd)
    , "   { " <> T.intercalate "\n   , " (map (makeStructField (makeFieldPrefix $ sd_name sd)) $ sd_fields sd)
    , "   } deriving (Show, Eq, Ord)"
    , ""
    , "instance " <> aesonPreds (sd_args sd) (aeson "ToJSON") <> aeson "ToJSON" <> " (" <> fullType <> ") where"
    , "    toJSON (" <> unTypeName (sd_name sd) <> " " <> funArgs <> ") ="
    , "        " <> aeson "object"
    , "        [ " <> T.intercalate "\n        , " (map makeToJsonFld $ sd_fields sd)
    , "        ]"
    , "instance " <> aesonPreds (sd_args sd) (aeson "FromJSON") <> aeson "FromJSON" <> " (" <> fullType <> ") where"
    , "    parseJSON ="
    , "        " <> aeson "withObject" <> " " <> T.pack (show $ unTypeName (sd_name sd)) <> " $ \\obj ->"
    , "        " <> unTypeName (sd_name sd)
    , "        <$> " <> T.intercalate "\n        <*> " (map makeFromJsonFld $ sd_fields sd)
    ]
    where
      jArg fld = "j_" <> (unFieldName $ sf_name fld)
      makeFromJsonFld fld =
          let name = unFieldName $ sf_name fld
          in case sf_type fld of
               (TyCon q _) | q == (bi_name tyMaybe) ->
                  "(join <$> (obj " <> aeson ".:?" <> " " <> T.pack (show name) <> "))"
               _ -> "obj " <> aeson ".:" <> " " <> T.pack (show name)
      makeToJsonFld fld =
          let name = unFieldName $ sf_name fld
              argName = jArg fld
          in "(" <> T.pack (show name) <> " " <> aeson ".=" <> " " <> argName <> ")"
      funArgs =
          T.intercalate " " $ map jArg (sd_fields sd)
      fullType =
          unTypeName (sd_name sd) <> " " <> T.intercalate " " (map unTypeVar $ sd_args sd)

aesonPreds :: [TypeVar] -> T.Text -> T.Text
aesonPreds args tyClass =
    if null args
    then ""
    else let mkPred (TypeVar tv) =
                 tyClass <> " " <> tv
         in "(" <> T.intercalate "," (map mkPred args) <> ") => "

makeEnumDef :: EnumDef -> T.Text
makeEnumDef ed =
    T.unlines
    [ "data " <> fullType
    , "   = " <> T.intercalate "\n   | " (map makeEnumChoice $ ed_choices ed)
    , "     deriving (Show, Eq, Ord)"
    , ""
    , "instance " <> aesonPreds (ed_args ed) (aeson "ToJSON") <> aeson "ToJSON" <> " (" <> fullType <> ") where"
    , "    toJSON x ="
    , "        case x of"
    , "          " <> T.intercalate "\n          " (map mkToJsonChoice $ ed_choices ed)
    , "instance " <> aesonPreds (ed_args ed) (aeson "FromJSON") <> aeson "FromJSON" <> " (" <> fullType <> ") where"
    , "    parseJSON = "
    , "        " <> aeson "withObject" <> " " <> T.pack (show $ unTypeName (ed_name ed)) <> " $ \\obj ->"
    , "        " <> T.intercalate "\n        <|> " (map mkFromJsonChoice $ ed_choices ed)
    , "        where"
    , "           eatBool :: Bool -> " <> aesonT "Parser" <> " ()"
    , "           eatBool _ = return ()"
    ]
    where
      mkFromJsonChoice ec =
          let constr = unChoiceName $ ec_name ec
              tag = camelTo2 '_' $ T.unpack constr
              (op, opEnd) =
                  case ec_arg ec of
                    Nothing -> ("<$ (eatBool <$> (", "))")
                    Just _ -> ("<$>", "")
          in "(" <> constr <> " " <> op <> " obj " <> (aeson ".:") <> " " <> T.pack (show tag) <> opEnd <> ")"
      mkToJsonChoice ec =
          let constr = unChoiceName $ ec_name ec
              tag = camelTo2 '_' $ T.unpack constr
              (argParam, argVal) =
                  case ec_arg ec of
                    Nothing -> ("", "True")
                    Just _ -> ("x", "x")
          in constr <> " " <> argParam <> " -> " <> aeson "object"
             <> " [" <> T.pack (show tag) <> " " <> aeson ".=" <> " " <> argVal <> "]"
      fullType =
          unTypeName (ed_name ed) <> " " <> T.intercalate " " (map unTypeVar $ ed_args ed)

makeEnumChoice :: EnumChoice -> T.Text
makeEnumChoice ec =
    (unChoiceName $ ec_name ec) <> fromMaybe "" (fmap ((<>) " !" . makeType) $ ec_arg ec)


makeStructField :: T.Text -> StructField -> T.Text
makeStructField prefix sf =
    prefix <> (unFieldName $ sf_name sf) <> " :: !" <> (makeType $ sf_type sf)

makeType :: Type -> T.Text
makeType t =
    case isBuiltIn t of
      Nothing ->
          case t of
            TyVar (TypeVar x) -> x
            TyCon qt args ->
                let ty = makeQualTypeName qt
                in case args of
                     [] -> ty
                     _ -> "(" <> ty <> " " <> T.intercalate " " (map makeType args) <> ")"
      Just (bi, tvars)
          | bi == tyString -> "T.Text"
          | bi == tyInt -> "Int"
          | bi == tyBool -> "Bool"
          | bi == tyFloat -> "Double"
          | bi == tyMaybe -> "(Maybe " <> T.intercalate " " (map makeType tvars) <> ")"
          | otherwise ->
              error $ "Elm: Unimplemented built in type: " ++ show t

makeQualTypeName :: QualTypeName -> T.Text
makeQualTypeName qtn =
    case unModuleName $ qtn_module qtn of
      [] -> ty
      _ -> printModuleName (qtn_module qtn) <> "." <> ty
    where
      ty = unTypeName $ qtn_type qtn
