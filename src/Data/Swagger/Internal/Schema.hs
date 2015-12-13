{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Data.Swagger.Internal.Schema where

import Control.Lens
import Control.Monad
import Control.Monad.Writer
import Data.Aeson
import Data.Char
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import "unordered-containers" Data.HashSet (HashSet)
import Data.Int
import Data.IntSet (IntSet)
import Data.IntMap (IntMap)
import Data.Map (Map)
import Data.Monoid
import Data.Proxy
import Data.Scientific (Scientific)
import Data.Set (Set)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Time
import Data.Word
import GHC.Generics

import Data.Swagger.Declare
import Data.Swagger.Internal
import Data.Swagger.Internal.ParamSchema (ToParamSchema(..))
import Data.Swagger.Lens
import Data.Swagger.SchemaOptions

-- | A @'Schema'@ with an optional name.
-- This name can be used in references.
type NamedSchema = (Maybe T.Text, Schema)

-- | Schema definitions, a mapping from schema name to @'Schema'@.
type Definitions = HashMap T.Text Schema

unnamed :: Schema -> NamedSchema
unnamed schema = (Nothing, schema)

named :: T.Text -> Schema -> NamedSchema
named name schema = (Just name, schema)

plain :: Schema -> Declare Definitions NamedSchema
plain = pure . unnamed

unname :: NamedSchema -> NamedSchema
unname (_, schema) = (Nothing, schema)

rename :: Maybe T.Text -> NamedSchema -> NamedSchema
rename name (_, schema) = (name, schema)

-- | Convert a type into @'Schema'@.
--
-- An example type and instance:
--
-- @
-- {-\# LANGUAGE OverloadedStrings \#-}   -- allows to write 'T.Text' literals
-- {-\# LANGUAGE OverloadedLists \#-}     -- allows to write 'Map' and 'HashMap' as lists
--
-- import Control.Lens
--
-- data Coord = Coord { x :: Double, y :: Double }
--
-- instance ToSchema Coord where
--   declareNamedSchema = pure (Just \"Coord\", schema)
--    where
--      schema = mempty
--        & schemaType .~ SwaggerObject
--        & schemaProperties .~
--            [ (\"x\", toSchemaRef (Proxy :: Proxy Double))
--            , (\"y\", toSchemaRef (Proxy :: Proxy Double))
--            ]
--        & schemaRequired .~ [ \"x\", \"y\" ]
-- @
--
-- Instead of manually writing your @'ToSchema'@ instance you can
-- use a default generic implementation of @'declareNamedSchema'@.
--
-- To do that, simply add @deriving 'Generic'@ clause to your datatype
-- and declare a @'ToSchema'@ instance for your datatype without
-- giving definition for @'declareNamedSchema'@.
--
-- For instance, the previous example can be simplified into this:
--
-- @
-- {-\# LANGUAGE DeriveGeneric \#-}
--
-- import GHC.Generics (Generic)
--
-- data Coord = Coord { x :: Double, y :: Double } deriving Generic
--
-- instance ToSchema Coord
-- @
class ToSchema a where
  -- | Convert a type into an optionally named schema
  -- together with all used definitions.
  -- Note that the schema itself is included in definitions
  -- only if it is recursive (and thus needs its definition in scope).
  declareNamedSchema :: proxy a -> Declare Definitions NamedSchema
  default declareNamedSchema :: (Generic a, GToSchema (Rep a)) => proxy a -> Declare Definitions NamedSchema
  declareNamedSchema = genericDeclareNamedSchema defaultSchemaOptions

-- | Convert a type into a schema and declare all used schema definitions.
declareSchema :: ToSchema a => proxy a -> Declare Definitions Schema
declareSchema = fmap snd . declareNamedSchema

-- | Convert a type into an optionally named schema.
toNamedSchema :: ToSchema a => proxy a -> NamedSchema
toNamedSchema = undeclare . declareNamedSchema

-- | Get type's schema name according to its @'ToSchema'@ instance.
schemaName :: ToSchema a => proxy a -> Maybe T.Text
schemaName = fst . toNamedSchema

-- | Convert a type into a schema.
toSchema :: ToSchema a => proxy a -> Schema
toSchema = snd . toNamedSchema

-- | Convert a type into a referenced schema if possible.
-- Only named schemas can be referenced, nameless schemas are inlined.
toSchemaRef :: ToSchema a => proxy a -> Referenced Schema
toSchemaRef = undeclare . declareSchemaRef

-- | Convert a type into a referenced schema if possible
-- and declare all used schema definitions.
-- Only named schemas can be referenced, nameless schemas are inlined.
--
-- Schema definitions are typically declared for every referenced schema.
-- If @'declareSchemaRef'@ returns a reference, a corresponding schema
-- will be declared (regardless of whether it is recusive or not).
declareSchemaRef :: ToSchema a => proxy a -> Declare Definitions (Referenced Schema)
declareSchemaRef proxy = do
  case toNamedSchema proxy of
    (Just name, schema) -> do
      -- This check is very important as it allows generically
      -- derive used definitions for recursive schemas.
      -- Lazy Declare monad allows toNamedSchema to ignore
      -- any declarations (which would otherwise loop) and
      -- retrieve the schema and its name to check if we
      -- have already declared it.
      -- If we have, we don't need to declare anything for
      -- this schema this time and thus simply return the reference.
      known <- looks (HashMap.member name)
      when (not known) $ do
        declare [(name, schema)]
        void $ declareNamedSchema proxy
      return $ Ref (Reference name)
    _ -> Inline <$> declareSchema proxy

class GToSchema (f :: * -> *) where
  gdeclareNamedSchema :: SchemaOptions -> proxy f -> Schema -> Declare Definitions NamedSchema

instance {-# OVERLAPPABLE #-} ToSchema a => ToSchema [a] where
  declareNamedSchema _ = do
    ref <- declareSchemaRef (Proxy :: Proxy a)
    return $ unnamed $ mempty
      & schemaType  .~ SwaggerArray
      & schemaItems ?~ SchemaItemsObject ref

instance {-# OVERLAPPING #-} ToSchema String where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Bool    where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Integer where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Int     where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Int8    where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Int16   where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Int32   where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Int64   where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Word    where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Word8   where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Word16  where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Word32  where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Word64  where declareNamedSchema = plain . paramSchemaToSchema

instance ToSchema Char        where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Scientific  where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Double      where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Float       where declareNamedSchema = plain . paramSchemaToSchema

instance ToSchema a => ToSchema (Maybe a) where
  declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy a)

instance (ToSchema a, ToSchema b) => ToSchema (Either a b)

instance ToSchema ()
instance (ToSchema a, ToSchema b) => ToSchema (a, b)
instance (ToSchema a, ToSchema b, ToSchema c) => ToSchema (a, b, c)
instance (ToSchema a, ToSchema b, ToSchema c, ToSchema d) => ToSchema (a, b, c, d)
instance (ToSchema a, ToSchema b, ToSchema c, ToSchema d, ToSchema e) => ToSchema (a, b, c, d, e)
instance (ToSchema a, ToSchema b, ToSchema c, ToSchema d, ToSchema e, ToSchema f) => ToSchema (a, b, c, d, e, f)
instance (ToSchema a, ToSchema b, ToSchema c, ToSchema d, ToSchema e, ToSchema f, ToSchema g) => ToSchema (a, b, c, d, e, f, g)

timeSchema :: T.Text -> Schema
timeSchema format = mempty
  & schemaType .~ SwaggerString
  & schemaFormat ?~ format
  & schemaMinLength ?~ toInteger (T.length format)

-- |
-- >>> toSchema (Proxy :: Proxy Day) ^. schemaFormat
-- Just "yyyy-mm-dd"
instance ToSchema Day where
  declareNamedSchema _ = pure $ named "Day" (timeSchema "yyyy-mm-dd")

-- |
-- >>> toSchema (Proxy :: Proxy LocalTime) ^. schemaFormat
-- Just "yyyy-mm-ddThh:MM:ss"
instance ToSchema LocalTime where
  declareNamedSchema _ = pure $ named "LocalTime" (timeSchema "yyyy-mm-ddThh:MM:ss")

-- |
-- >>> toSchema (Proxy :: Proxy ZonedTime) ^. schemaFormat
-- Just "yyyy-mm-ddThh:MM:ss(Z|+hh:MM)"
instance ToSchema ZonedTime where
  declareNamedSchema _ = pure $ named "ZonedTime" $ timeSchema "yyyy-mm-ddThh:MM:ss(Z|+hh:MM)"
    & schemaMinLength ?~ toInteger (T.length "yyyy-mm-ddThh:MM:ssZ")

instance ToSchema NominalDiffTime where
  declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy Integer)

-- |
-- >>> toSchema (Proxy :: Proxy UTCTime) ^. schemaFormat
-- Just "yyyy-mm-ddThh:MM:ssZ"
instance ToSchema UTCTime where
  declareNamedSchema _ = pure $ named "UTCTime" (timeSchema "yyyy-mm-ddThh:MM:ssZ")

instance ToSchema T.Text where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema TL.Text where declareNamedSchema = plain . paramSchemaToSchema

instance ToSchema IntSet where declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy (Set Int))

-- | NOTE: This schema does not account for the uniqueness of keys.
instance ToSchema a => ToSchema (IntMap a) where
  declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy [(Int, a)])

instance ToSchema a => ToSchema (Map String a) where
  declareNamedSchema _ = do
    schema <- declareSchema (Proxy :: Proxy a)
    return $ unnamed $ mempty
      & schemaType  .~ SwaggerObject
      & schemaAdditionalProperties ?~ schema

instance ToSchema a => ToSchema (Map T.Text  a) where declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy (Map String a))
instance ToSchema a => ToSchema (Map TL.Text a) where declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy (Map String a))

instance ToSchema a => ToSchema (HashMap String  a) where declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy (Map String a))
instance ToSchema a => ToSchema (HashMap T.Text  a) where declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy (Map String a))
instance ToSchema a => ToSchema (HashMap TL.Text a) where declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy (Map String a))

instance ToSchema a => ToSchema (Set a) where
  declareNamedSchema _ = do
    schema <- declareSchema (Proxy :: Proxy [a])
    return $ unnamed $ schema
      & schemaUniqueItems ?~ True

instance ToSchema a => ToSchema (HashSet a) where declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy (Set a))

instance ToSchema All where declareNamedSchema = plain . paramSchemaToSchema
instance ToSchema Any where declareNamedSchema = plain . paramSchemaToSchema

instance ToSchema a => ToSchema (Sum a)     where declareNamedSchema _ = unname <$> declareNamedSchema (Proxy :: Proxy a)
instance ToSchema a => ToSchema (Product a) where declareNamedSchema _ = unname <$> declareNamedSchema (Proxy :: Proxy a)
instance ToSchema a => ToSchema (First a)   where declareNamedSchema _ = unname <$> declareNamedSchema (Proxy :: Proxy a)
instance ToSchema a => ToSchema (Last a)    where declareNamedSchema _ = unname <$> declareNamedSchema (Proxy :: Proxy a)
instance ToSchema a => ToSchema (Dual a)    where declareNamedSchema _ = unname <$> declareNamedSchema (Proxy :: Proxy a)

-- | Default schema for @'Bounded'@, @'Integral'@ types.
toSchemaBoundedIntegral :: forall a proxy. (Bounded a, Integral a) => proxy a -> Schema
toSchemaBoundedIntegral _ = mempty
  & schemaType .~ SwaggerInteger
  & schemaMinimum ?~ fromInteger (toInteger (minBound :: a))
  & schemaMaximum ?~ fromInteger (toInteger (maxBound :: a))

-- | Default generic named schema for @'Bounded'@, @'Integral'@ types.
genericToNamedSchemaBoundedIntegral :: forall a d f proxy.
  ( Bounded a, Integral a
  , Generic a, Rep a ~ D1 d f, Datatype d)
  => SchemaOptions -> proxy a -> NamedSchema
genericToNamedSchemaBoundedIntegral opts proxy
  = (gdatatypeSchemaName opts (Proxy :: Proxy d), toSchemaBoundedIntegral proxy)

-- | A configurable generic @'Schema'@ creator.
genericDeclareSchema :: (Generic a, GToSchema (Rep a)) => SchemaOptions -> proxy a -> Declare Definitions Schema
genericDeclareSchema opts proxy = snd <$> genericDeclareNamedSchema opts proxy

-- | A configurable generic @'NamedSchema'@ creator.
-- This function applied to @'defaultSchemaOptions'@
-- is used as the default for @'declareNamedSchema'@
-- when the type is an instance of @'Generic'@.
genericDeclareNamedSchema :: forall a proxy. (Generic a, GToSchema (Rep a)) => SchemaOptions -> proxy a -> Declare Definitions NamedSchema
genericDeclareNamedSchema opts _ = gdeclareNamedSchema opts (Proxy :: Proxy (Rep a)) mempty

gdatatypeSchemaName :: forall proxy d. Datatype d => SchemaOptions -> proxy d -> Maybe T.Text
gdatatypeSchemaName opts _ = case name of
  (c:_) | isAlpha c && isUpper c -> Just (T.pack name)
  _ -> Nothing
  where
    name = datatypeNameModifier opts (datatypeName (Proxy3 :: Proxy3 d f a))

-- | Lift a plain @'ParamSchema'@ into a model @'NamedSchema'@.
paramSchemaToNamedSchema :: forall a d f proxy.
  (ToParamSchema a, Generic a, Rep a ~ D1 d f, Datatype d)
  => SchemaOptions -> proxy a -> NamedSchema
paramSchemaToNamedSchema opts proxy = (gdatatypeSchemaName opts (Proxy :: Proxy d), paramSchemaToSchema proxy)

-- | Lift a plain @'ParamSchema'@ into a model @'Schema'@.
paramSchemaToSchema :: forall a proxy. ToParamSchema a => proxy a -> Schema
paramSchemaToSchema _ = mempty & schemaParamSchema .~ toParamSchema (Proxy :: Proxy a)

nullarySchema :: Schema
nullarySchema = mempty
  & schemaType .~ SwaggerArray
  & schemaEnum ?~ [ toJSON () ]

gtoNamedSchema :: GToSchema f => SchemaOptions -> proxy f -> NamedSchema
gtoNamedSchema opts proxy = undeclare $ gdeclareNamedSchema opts proxy mempty

gdeclareSchema :: GToSchema f => SchemaOptions -> proxy f -> Declare Definitions Schema
gdeclareSchema opts proxy = snd <$> gdeclareNamedSchema opts proxy mempty

instance GToSchema U1 where
  gdeclareNamedSchema _ _ _ = plain nullarySchema

instance (GToSchema f, GToSchema g) => GToSchema (f :*: g) where
  gdeclareNamedSchema opts _ schema = do
    (_, gschema) <- gdeclareNamedSchema opts (Proxy :: Proxy g) schema
    gdeclareNamedSchema opts (Proxy :: Proxy f) gschema

instance (Datatype d, GToSchema f) => GToSchema (D1 d f) where
  gdeclareNamedSchema opts _ s = rename name <$> gdeclareNamedSchema opts (Proxy :: Proxy f) s
    where
      name = gdatatypeSchemaName opts (Proxy :: Proxy d)

instance {-# OVERLAPPABLE #-} GToSchema f => GToSchema (C1 c f) where
  gdeclareNamedSchema opts _ = gdeclareNamedSchema opts (Proxy :: Proxy f)

-- | Single field constructor.
instance (Selector s, GToSchema f) => GToSchema (C1 c (S1 s f)) where
  gdeclareNamedSchema opts _ s
    | unwrapUnaryRecords opts = fieldSchema
    | otherwise = do
        (_, schema) <- recordSchema
        case schema ^. schemaItems of
          Just (SchemaItemsArray [_]) -> fieldSchema
          _ -> pure (unnamed schema)
    where
      recordSchema = gdeclareNamedSchema opts (Proxy :: Proxy (S1 s f)) s
      fieldSchema  = gdeclareNamedSchema opts (Proxy :: Proxy f) s

gdeclareSchemaRef :: GToSchema a => SchemaOptions -> proxy a -> Declare Definitions (Referenced Schema)
gdeclareSchemaRef opts proxy = do
  case gtoNamedSchema opts proxy of
    (Just name, schema) -> do
      -- This check is very important as it allows generically
      -- derive used definitions for recursive schemas.
      -- Lazy Declare monad allows toNamedSchema to ignore
      -- any declarations (which would otherwise loop) and
      -- retrieve the schema and its name to check if we
      -- have already declared it.
      -- If we have, we don't need to declare anything for
      -- this schema this time and thus simply return the reference.
      known <- looks (HashMap.member name)
      when (not known) $ do
        declare [(name, schema)]
        void $ gdeclareNamedSchema opts proxy mempty
      return $ Ref (Reference name)
    _ -> Inline <$> gdeclareSchema opts proxy

appendItem :: Referenced Schema -> Maybe SchemaItems -> Maybe SchemaItems
appendItem x Nothing = Just (SchemaItemsArray [x])
appendItem x (Just (SchemaItemsArray xs)) = Just (SchemaItemsArray (x:xs))
appendItem _ _ = error "GToSchema.appendItem: cannot append to SchemaItemsObject"

withFieldSchema :: forall proxy s f. (Selector s, GToSchema f) =>
  SchemaOptions -> proxy s f -> Bool -> Schema -> Declare Definitions Schema
withFieldSchema opts _ isRequiredField schema = do
  ref <- gdeclareSchemaRef opts (Proxy :: Proxy f)
  return $
    if T.null fname
      then schema
        & schemaType .~ SwaggerArray
        & schemaItems %~ appendItem ref
      else schema
        & schemaType .~ SwaggerObject
        & schemaProperties . at fname ?~ ref
        & if isRequiredField
            then schemaRequired %~ (fname :)
            else id
  where
    fname = T.pack (fieldLabelModifier opts (selName (Proxy3 :: Proxy3 s f p)))

-- | Optional record fields.
instance {-# OVERLAPPING #-} (Selector s, ToSchema c) => GToSchema (S1 s (K1 i (Maybe c))) where
  gdeclareNamedSchema opts _ = fmap unnamed . withFieldSchema opts (Proxy2 :: Proxy2 s (K1 i (Maybe c))) False

-- | Record fields.
instance {-# OVERLAPPABLE #-} (Selector s, GToSchema f) => GToSchema (S1 s f) where
  gdeclareNamedSchema opts _ = fmap unnamed . withFieldSchema opts (Proxy2 :: Proxy2 s f) True

instance {-# OVERLAPPING #-} ToSchema c => GToSchema (K1 i (Maybe c)) where
  gdeclareNamedSchema _ _ _ = declareNamedSchema (Proxy :: Proxy c)

instance {-# OVERLAPPABLE #-} ToSchema c => GToSchema (K1 i c) where
  gdeclareNamedSchema _ _ _ = declareNamedSchema (Proxy :: Proxy c)

instance (GSumToSchema f, GSumToSchema g) => GToSchema (f :+: g) where
  gdeclareNamedSchema opts _ s
    | allNullaryToStringTag opts && allNullary = pure $ unnamed (toStringTag sumSchema)
    | otherwise = (unnamed . fst) <$> runWriterT declareSumSchema
    where
      declareSumSchema = gsumToSchema opts (Proxy :: Proxy (f :+: g)) s
      (sumSchema, All allNullary) = undeclare (runWriterT declareSumSchema)

      toStringTag schema = mempty
        & schemaType .~ SwaggerString
        & schemaEnum ?~ map toJSON (schema ^.. schemaProperties.ifolded.asIndex)

type AllNullary = All

class GSumToSchema f where
  gsumToSchema :: SchemaOptions -> proxy f -> Schema -> WriterT AllNullary (Declare Definitions) Schema

instance (GSumToSchema f, GSumToSchema g) => GSumToSchema (f :+: g) where
  gsumToSchema opts _ = gsumToSchema opts (Proxy :: Proxy f) <=< gsumToSchema opts (Proxy :: Proxy g)

gsumConToSchema :: forall c f proxy. (GToSchema (C1 c f), Constructor c) =>
  SchemaOptions -> proxy (C1 c f) -> Schema -> Declare Definitions Schema
gsumConToSchema opts _ schema = do
  ref <- gdeclareSchemaRef opts (Proxy :: Proxy (C1 c f))
  return $ schema
    & schemaType .~ SwaggerObject
    & schemaProperties . at tag ?~ ref
    & schemaMaxProperties ?~ 1
    & schemaMinProperties ?~ 1
  where
    tag = T.pack (constructorTagModifier opts (conName (Proxy3 :: Proxy3 c f p)))

instance {-# OVERLAPPABLE #-} (Constructor c, GToSchema f) => GSumToSchema (C1 c f) where
  gsumToSchema opts proxy schema = do
    tell (All False)
    lift $ gsumConToSchema opts proxy schema

instance (Constructor c, Selector s, GToSchema f) => GSumToSchema (C1 c (S1 s f)) where
  gsumToSchema opts proxy schema = do
    tell (All False)
    lift $ gsumConToSchema opts proxy schema

instance Constructor c => GSumToSchema (C1 c U1) where
  gsumToSchema opts proxy = lift . gsumConToSchema opts proxy

data Proxy2 a b = Proxy2

data Proxy3 a b c = Proxy3
