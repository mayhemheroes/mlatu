{-# LANGUAGE DataKinds #-}

-- |
-- Module      : Mlatu.Parse
-- Description : Parsing from tokens to terms
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Parse
  ( generalName,
    fragment,
  )
where

import Data.List (findIndex, foldl1, zipWith3)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Mlatu.DataConstructor (DataConstructor (DataConstructor))
import Mlatu.DataConstructor qualified as DataConstructor
import Mlatu.Declaration (Declaration (..))
import Mlatu.Declaration qualified as Declaration
import Mlatu.Definition (Definition (..))
import Mlatu.Definition qualified as Definition
import Mlatu.Desugar.Data qualified as Data
import Mlatu.Element (Element)
import Mlatu.Element qualified as Element
import Mlatu.Entry.Category (Category)
import Mlatu.Entry.Category qualified as Category
import Mlatu.Entry.Merge qualified as Merge
import Mlatu.Entry.Parameter (Parameter (Parameter))
import Mlatu.Entry.Parent qualified as Parent
import Mlatu.Fragment (Fragment)
import Mlatu.Fragment qualified as Fragment
import Mlatu.Ice (ice)
import Mlatu.Informer (Informer (..), errorCheckpoint)
import Mlatu.Kind (Kind (..))
import Mlatu.Located (Located)
import Mlatu.Located qualified as Located
import Mlatu.Metadata (Metadata (Metadata))
import Mlatu.Metadata qualified as Metadata
import Mlatu.Monad (M)
import Mlatu.Name
  ( GeneralName (..),
    Qualified (Qualified),
    Qualifier (Qualifier),
    Root (Absolute, Relative),
    Unqualified (..),
    qualifierName,
    unqualifiedName,
  )
import Mlatu.Origin (Origin)
import Mlatu.Origin qualified as Origin
import Mlatu.Parser (Parser, getTokenOrigin, parserMatch, parserMatch_)
import Mlatu.Report qualified as Report
import Mlatu.Signature (Signature)
import Mlatu.Signature qualified as Signature
import Mlatu.Term (Case (..), Else (..), MatchHint (..), Term (..), Value (..), compose)
import Mlatu.Term qualified as Term
import Mlatu.Token (Token)
import Mlatu.Token qualified as Token
import Mlatu.Tokenize (tokenize)
import Mlatu.TypeAlias (TypeAlias (..))
import Mlatu.TypeAlias qualified as TypeAlias
import Mlatu.TypeDefinition (TypeDefinition (TypeDefinition))
import Mlatu.TypeDefinition qualified as TypeDefinition
import Mlatu.Vocabulary qualified as Vocabulary
import Optics
import Relude hiding (Compose, Constraint)
import Relude.Unsafe qualified as Unsafe
import Text.Parsec ((<?>))
import Text.Parsec qualified as Parsec
import Text.Parsec.Pos (SourcePos)

-- | Parses a program fragment.
fragment ::
  -- | Initial source line (e.g. for REPL offset).
  Int ->
  -- | Source file path.
  FilePath ->
  -- | List of permissions granted to @main@.
  [GeneralName] ->
  -- | Override name of @main@.
  Maybe Qualified ->
  -- | Input tokens.
  [Located Token] ->
  -- | Parsed program fragment.
  M (Fragment ())
fragment line path mainPermissions mainName tokens =
  let parsed =
        Parsec.runParser
          (fragmentParser mainPermissions mainName)
          Vocabulary.global
          path
          tokens
   in case parsed of
        Left parseError -> do
          report $ Report.parseError parseError
          halt
        Right result -> pure (Data.desugar (insertMain result))
  where
    isMain = (fromMaybe Definition.mainName mainName ==) . view Definition.name
    insertMain f = case find isMain $ view Fragment.definitions f of
      Just {} -> f
      Nothing ->
        over
          Fragment.definitions
          ( Definition.main
              mainPermissions
              mainName
              (Term.identityCoercion () (Origin.point path line 1))
              :
          )
          f

-- | Parses only a name.
generalName :: (Informer m) => Int -> FilePath -> Text -> m GeneralName
generalName line path text = do
  tokens <- tokenize line path text
  errorCheckpoint
  let parsed = Parsec.runParser nameParser Vocabulary.global path tokens
  case parsed of
    Left parseError -> do
      report $ Report.parseError parseError
      halt
    Right name -> pure name

fragmentParser ::
  [GeneralName] -> Maybe Qualified -> Parser (Fragment ())
fragmentParser mainPermissions mainName =
  partitionElements mainPermissions mainName
    <$> elementsParser <* Parsec.eof

elementsParser :: Parser [Element ()]
elementsParser =
  asum
    <$> many
      ( moduleParser
          <|> ( do
                  (defs, td) <- recordParser
                  pure (Element.TypeDefinition td : (Element.Definition <$> defs))
              )
          <|> one
          <$> elementParser
      )

partitionElements ::
  [GeneralName] ->
  Maybe Qualified ->
  [Element ()] ->
  Fragment ()
partitionElements mainPermissions mainName = rev . foldr go mempty
  where
    rev :: Fragment () -> Fragment ()
    rev =
      over Fragment.declarations reverse
        . over Fragment.definitions reverse
        . over Fragment.metadata reverse
        . over Fragment.types reverse
        . over Fragment.aliases reverse

    go :: Element () -> Fragment () -> Fragment ()
    go = \case
      Element.Declaration x -> over Fragment.declarations (x :)
      Element.Definition x -> over Fragment.definitions (x :)
      Element.Metadata x -> over Fragment.metadata (x :)
      Element.TypeDefinition x -> over Fragment.types (x :)
      Element.TypeAlias x -> over Fragment.aliases (x :)
      Element.Term x ->
        over
          Fragment.definitions
          ( \defs ->
              case findIndex
                ((== fromMaybe Definition.mainName mainName) . view Definition.name)
                defs of
                Just index -> case splitAt index defs of
                  (a, existing : b) ->
                    a
                      ++ over Definition.body (`composeUnderLambda` x) existing :
                    b
                  _nonMain -> ice "Mlatu.Parse.partitionElements - cannot find main definition"
                Nothing ->
                  Definition.main mainPermissions mainName x : defs
          )
        where
          -- In top-level code, we want local parameteriable bindings to remain in scope even
          -- when separated by other top-level program elements, e.g.:
          --
          --     1 -> x;
          --     define f (int -> int) { (+ 1) }
          --     x say  // should work
          --
          -- As such, when composing top-level code, we extend the scope of lambdas to
          -- include subsequent expressions.

          composeUnderLambda :: Term () -> Term () -> Term ()
          composeUnderLambda (Lambda typ name parameterType body origin) term =
            Lambda typ name parameterType (composeUnderLambda body term) origin
          composeUnderLambda a b = Compose () a b

moduleParser :: Parser [Element ()]
moduleParser = (<?> "module definition") $ do
  parserMatch_ Token.Module
  original@(Qualifier _ outer) <- Parsec.getState
  vocabularyName <- nameParser <?> "module name"
  let (inner, name) = case vocabularyName of
        QualifiedName
          (Qualified (Qualifier _root qualifier) (Unqualified unqualified)) ->
            (qualifier, unqualified)
        UnqualifiedName (Unqualified unqualified) -> ([], unqualified)
        LocalName {} -> ice "Mlatu.Parse.moduleParser - local name should not appear as vocabulary name"
  Parsec.putState (Qualifier Absolute (outer ++ inner ++ [name]))
  Parsec.choice
    [ [] <$ parserMatchOperator ";",
      do
        es <- blockedParser elementsParser
        Parsec.putState original
        pure es
    ]

blockedParser :: Parser a -> Parser a
blockedParser =
  Parsec.between
    (parserMatch Token.BlockBegin)
    (parserMatch Token.BlockEnd)

groupedParser :: Parser a -> Parser a
groupedParser =
  Parsec.between
    (parserMatch Token.GroupBegin)
    (parserMatch Token.GroupEnd)

groupParser :: Parser (Term ())
groupParser = do
  origin <- getTokenOrigin
  groupedParser $ Group . compose () origin <$> Parsec.many1 termParser

bracketedParser :: Parser a -> Parser a
bracketedParser =
  Parsec.between
    (parserMatch Token.VectorBegin)
    (parserMatch Token.VectorEnd)

nameParser :: Parser GeneralName
nameParser = (<?> "name") $ do
  global <-
    isJust
      <$> Parsec.optionMaybe
        (parserMatch Token.Ignore <* parserMatch Token.Dot)
  parts <- unqualifiedNameParser `Parsec.sepBy1` parserMatch Token.Dot
  pure $ case parts of
    [unqualified] ->
      ( if global
          then QualifiedName . Qualified Vocabulary.global
          else UnqualifiedName
      )
        unqualified
    _list ->
      let parts' = (\(Unqualified part) -> part) <$> parts
          qualifier = Unsafe.fromJust (viaNonEmpty init parts')
          unqualified = Unsafe.fromJust (viaNonEmpty last parts)
       in QualifiedName
            ( Qualified
                (Qualifier (if global then Absolute else Relative) qualifier)
                unqualified
            )

unqualifiedNameParser :: Parser Unqualified
unqualifiedNameParser =
  (<?> "unqualified name") $
    lowerNameParser <|> upperNameParser <|> operatorNameParser

lowerNameParser :: Parser Unqualified
lowerNameParser = (<?> "word name") $
  parseOne $
    \token -> case Located.item token of
      Token.LowerWord name -> Just name
      _nonWord -> Nothing

upperNameParser :: Parser Unqualified
upperNameParser = (<?> "initial-capital word name") $
  parseOne $
    \token -> case Located.item token of
      Token.UpperWord name -> Just name
      _nonWord -> Nothing

operatorNameParser :: Parser Unqualified
operatorNameParser = (<?> "operator name") $ do
  angles <- many $
    parseOne $ \token -> case Located.item token of
      Token.AngleBegin -> Just "<"
      Token.AngleEnd -> Just ">"
      _nonAngle -> Nothing
  rest <- parseOne $ \token -> case Located.item token of
    Token.Operator (Unqualified name) -> Just name
    _nonUnqualifiedOperator -> Nothing
  pure $ Unqualified $ Text.concat $ angles ++ [rest]

parseOne :: (Located Token -> Maybe a) -> Parser a
parseOne = Parsec.tokenPrim show advance
  where
    advance :: SourcePos -> t -> [Located Token] -> SourcePos
    advance _ _ (token : _) = Origin.begin $ Located.origin token
    advance sourcePos _ _ = sourcePos

elementParser :: Parser (Element ())
elementParser =
  (<?> "top-level program element") $
    Parsec.choice
      [ Element.Definition
          <$> Parsec.choice
            [ basicDefinitionParser,
              instanceParser,
              permissionParser
            ],
        Element.Declaration
          <$> Parsec.choice
            [ traitParser,
              intrinsicParser
            ],
        Element.TypeAlias <$> typeAliasParser,
        Element.Metadata <$> metadataParser,
        Element.TypeDefinition <$> typeDefinitionParser,
        do
          origin <- getTokenOrigin
          Element.Term . compose () origin <$> Parsec.many1 termParser
      ]

metadataParser :: Parser Metadata
metadataParser = (<?> "metadata block") $ do
  origin <- getTokenOrigin <* parserMatch Token.About
  -- FIXME: This only allows metadata to be defined for elements within the
  -- current vocabulary.
  name <-
    Qualified <$> Parsec.getState
      <*> Parsec.choice
        [ unqualifiedNameParser <?> "word identifier",
          (parserMatch Token.Type *> lowerNameParser)
            <?> "'type' and type identifier"
        ]
  fields <-
    blockedParser $
      many $
        (,)
          <$> (lowerNameParser <?> "metadata key identifier")
          <*> (blockParser <?> "metadata value block")
  pure
    Metadata
      { Metadata._fields = Map.fromList fields,
        Metadata._name = QualifiedName name,
        Metadata._origin = origin
      }

typeAliasParser :: Parser TypeAlias
typeAliasParser = (<?> "type alias definition") $ do
  origin <- getTokenOrigin <* parserMatch Token.Alias
  newName <- unqualifiedNameParser <?> "type alias"
  oldName <- qualifiedNameParser <?> "type name"
  pure
    TypeAlias
      { TypeAlias._name = newName,
        TypeAlias._alias = oldName,
        TypeAlias._origin = origin
      }

typeDefinitionParser :: Parser TypeDefinition
typeDefinitionParser = (<?> "type definition") $ do
  origin <- getTokenOrigin <* parserMatch Token.Type
  parameters <- Parsec.option [] $ groupedParser (Parsec.many parameter)
  name <- qualifiedNameParser <?> "type definition name"
  constructors <- blockedParser $ many constructorParser
  pure
    TypeDefinition
      { TypeDefinition._constructors = constructors,
        TypeDefinition._name = name,
        TypeDefinition._origin = origin,
        TypeDefinition._parameters = reverse parameters
      }

constructorParser :: Parser DataConstructor
constructorParser = (<?> "constructor definition") $ do
  origin <- getTokenOrigin <* parserMatch Token.Case
  name <- lowerNameParser <?> "constructor name"
  fields <-
    (<?> "constructor fields") $
      Parsec.option [] $ groupedParser (typeParser `Parsec.sepEndBy` commaParser)
  pure
    DataConstructor
      { DataConstructor._fields = fields,
        DataConstructor._name = name,
        DataConstructor._origin = origin
      }

recordParser :: Parser ([Definition ()], TypeDefinition)
recordParser = (<?> "record definition") $ do
  origin <- getTokenOrigin <* parserMatch Token.Record
  parameters <- Parsec.option [] $ groupedParser (Parsec.many parameter)
  recordName <- qualifiedNameParser <?> "record  name"
  fields <-
    blockedParser $
      many
        ( (<?> "record field definition") $ do
            origin <- getTokenOrigin <* parserMatch Token.Field
            name <- lowerNameParser <?> "record field name"
            let qualifiedName = Qualified (qualifierName recordName) name
            sig <- groupedParser typeParser <?> "record field signature"
            pure
              ( \num1 num2 ->
                  Definition
                    { Definition._body =
                        Match
                          AnyMatch
                          ()
                          [ Case
                              (UnqualifiedName ("mk-" <> unqualifiedName recordName))
                              ( compose
                                  ()
                                  origin
                                  ( replicate num2 (Word () "drop" [] origin)
                                      <> replicate num1 (Word () "nip" [] origin)
                                  )
                              )
                              origin
                          ]
                          (DefaultElse () origin)
                          origin,
                      Definition._category = Category.Deconstructor,
                      Definition._inferSignature = True,
                      Definition._merge = Merge.Deny,
                      Definition._name = qualifiedName,
                      Definition._origin = origin,
                      Definition._parent = Just $ Parent.Record recordName,
                      Definition._signature =
                        Signature.Quantified
                          parameters
                          ( Signature.Function
                              [ foldl'
                                  (\a b -> Signature.Application a b origin)
                                  (Signature.Variable (QualifiedName recordName) origin)
                                  $ ( \(Parameter po p _ _) ->
                                        Signature.Variable (UnqualifiedName p) po
                                    )
                                    <$> parameters
                              ]
                              [sig]
                              []
                              origin
                          )
                          origin
                    },
                sig
              )
        )
  let list = [0 .. (length fields - 1)]
  pure
    ( zipWith3 id (fst <$> fields) list (reverse list),
      TypeDefinition
        { TypeDefinition._constructors = [DataConstructor (snd <$> fields) ("mk-" <> unqualifiedName recordName) origin],
          TypeDefinition._name = recordName,
          TypeDefinition._origin = origin,
          TypeDefinition._parameters = reverse parameters
        }
    )

traitParser :: Parser Declaration
traitParser =
  (<?> "trait declaration") $
    declarationParser Token.Trait Declaration.Trait

intrinsicParser :: Parser Declaration
intrinsicParser =
  (<?> "intrinsic declaration") $
    declarationParser Token.Intrinsic Declaration.Intrinsic

declarationParser ::
  Token ->
  Declaration.Category ->
  Parser Declaration
declarationParser keyword category = do
  origin <- getTokenOrigin <* parserMatch keyword
  suffix <- unqualifiedNameParser <?> "declaration name"
  name <- Qualified <$> Parsec.getState <*> pure suffix
  sig <- signatureParser <?> "declaration signature"
  pure
    Declaration
      { Declaration._category = category,
        Declaration._name = name,
        Declaration._origin = origin,
        Declaration._signature = sig
      }

typeParser :: Parser Signature
typeParser = Parsec.try functionTypeParser <|> basicTypeParser <?> "type"

functionTypeParser :: Parser Signature
functionTypeParser = (<?> "function type") $ do
  (effect, origin) <-
    Parsec.choice
      [ stackSignature,
        arrowSignature
      ]
  perms <- Parsec.option [] permissions
  pure (effect perms origin)
  where
    stackSignature :: Parser ([GeneralName] -> Origin -> Signature, Origin)
    stackSignature = (<?> "stack function type") $ do
      leftparameter <- UnqualifiedName <$> stack
      leftTypes <- Parsec.option [] (commaParser *> left)
      origin <- arrow
      rightparameter <- UnqualifiedName <$> stack
      rightTypes <- Parsec.option [] (commaParser *> right)
      pure
        ( Signature.StackFunction
            (Signature.Variable leftparameter origin)
            leftTypes
            (Signature.Variable rightparameter origin)
            rightTypes,
          origin
        )
      where
        stack :: Parser Unqualified
        stack = upperNameParser

    arrowSignature :: Parser ([GeneralName] -> Origin -> Signature, Origin)
    arrowSignature = (<?> "arrow function type") $ do
      leftTypes <- left
      origin <- arrow
      rightTypes <- right
      pure (Signature.Function leftTypes rightTypes, origin)

    permissions :: Parser [GeneralName]
    permissions = (<?> "permission labels") $ do
      parserMatch_ Token.AngleBegin
      ps <- nameParser `Parsec.sepBy1` parserMatchOperator "+"
      parserMatch_ Token.AngleEnd
      pure ps

    left, right :: Parser [Signature]
    left = basicTypeParser `Parsec.sepEndBy` commaParser
    right = typeParser `Parsec.sepEndBy` commaParser

    arrow :: Parser Origin
    arrow = getTokenOrigin <* parserMatch Token.Arrow

commaParser :: Parser ()
commaParser = void $ parserMatch Token.Comma

basicTypeParser' :: Parser Signature
basicTypeParser' =
  Parsec.choice
    [ groupedParser (quantifiedParser typeParser <|> typeParser),
      Parsec.try $ do
        origin <- getTokenOrigin
        name <- nameParser
        guard $ name /= "+"
        pure $ Signature.Variable name origin
    ]

basicTypeParser :: Parser Signature
basicTypeParser = (<?> "basic type") $ foldl1 (\a b -> Signature.Application a b (Signature.origin a)) . reverse <$> Parsec.many1 basicTypeParser'

parameter :: Parser Parameter
parameter = do
  origin <- getTokenOrigin
  (kind, name) <-
    Parsec.choice
      [ (Permission,) <$> (parserMatchOperator "+" *> lowerNameParser),
        (Stack,) <$> upperNameParser,
        (Value,) <$> lowerNameParser
      ]
  pure $ Parameter origin name kind Nothing

quantifiedParser :: Parser Signature -> Parser Signature
quantifiedParser thing = do
  origin <- getTokenOrigin <* parserMatch_ Token.For
  params <- Parsec.many1 parameter
  parserMatch_ Token.Dot
  Signature.Quantified params <$> thing <*> pure origin

basicDefinitionParser :: Parser (Definition ())
basicDefinitionParser =
  (<?> "word definition") $
    definitionParser Token.Define Category.Word

instanceParser :: Parser (Definition ())
instanceParser =
  (<?> "instance definition") $
    definitionParser Token.Instance Category.Instance

permissionParser :: Parser (Definition ())
permissionParser =
  (<?> "permission definition") $
    definitionParser Token.Permission Category.Permission

-- | Unqualified or partially qualified name, implicitly qualified by the
-- current vocabulary, or fully qualified (global) name.
qualifiedNameParser :: Parser Qualified
qualifiedNameParser = (<?> "optionally qualified name") $ do
  suffix <- nameParser
  case suffix of
    QualifiedName qualified@(Qualified (Qualifier root parts) unqualified) ->
      case root of
        -- Fully qualified name: pure it as-is.
        Absolute -> pure qualified
        -- Partially qualified name: add current vocab prefix to qualifier.
        Relative -> do
          Qualifier root' prefixParts <- Parsec.getState
          pure (Qualified (Qualifier root' (prefixParts ++ parts)) unqualified)
    -- Unqualified name: use current vocab prefix as qualifier.
    UnqualifiedName unqualified ->
      Qualified <$> Parsec.getState <*> pure unqualified
    LocalName _ -> ice "Mlatu.Parse.qualifiedNameParser - name parser should only pure qualified or unqualified name"

definitionParser :: Token -> Category -> Parser (Definition ())
definitionParser keyword category = do
  origin <- getTokenOrigin <* parserMatch keyword
  name <- qualifiedNameParser <?> "definition name"
  sig <- signatureParser
  body <- blockLikeParser <?> "definition body"
  pure
    Definition
      { Definition._body = body,
        Definition._category = category,
        Definition._inferSignature = False,
        Definition._merge = Merge.Deny,
        Definition._name = name,
        Definition._origin = origin,
        -- HACK: Should be passed in from outside?
        Definition._parent = case keyword of
          Token.Instance -> Just $ Parent.Trait name
          _nonInstance -> Nothing,
        Definition._signature = sig
      }

signatureParser :: Parser Signature
signatureParser = groupedParser (quantifiedParser functionTypeParser <|> functionTypeParser) <?> "type signature"

blockParser :: Parser (Term ())
blockParser =
  (blockedParser blockContentsParser <|> reference)
    <?> "block or reference"

reference :: Parser (Term ())
reference =
  parserMatch_ Token.Reference
    *> Parsec.choice
      [ do
          origin <- getTokenOrigin
          Word () <$> nameParser <*> pure [] <*> pure origin,
        termParser
      ]

blockContentsParser :: Parser (Term ())
blockContentsParser = do
  origin <- getTokenOrigin
  terms <- many termParser
  let origin' = case terms of
        x : _ -> Term.origin x
        _emptyList -> origin
  pure $ foldr (Compose ()) (Term.identityCoercion () origin') terms

termParser :: Parser (Term ())
termParser = (<?> "expression") $ do
  origin <- getTokenOrigin
  Parsec.choice
    [ Parsec.try intParser,
      Parsec.try (uncurry (Push ()) <$> parseOne toLiteral <?> "literal"),
      do
        name <- nameParser
        pure (Word () name [] origin),
      Parsec.try sectionParser,
      Parsec.try groupParser <?> "parenthesized expression",
      vectorParser,
      lambdaParser,
      matchParser,
      ifParser,
      doParser,
      Push () <$> blockValue <*> pure origin,
      withParser,
      asParser
    ]

toLiteral :: Located Token -> Maybe (Value (), Origin)
toLiteral token = case Located.item token of
  Token.Character x -> Just (Character x, origin)
  Token.Text x -> Just (Text x, origin)
  _nonLiteral -> Nothing
  where
    origin :: Origin
    origin = Located.origin token

intParser :: Parser (Term ())
intParser = do
  (num, origin) <-
    parseOne
      ( \token -> case Located.item token of
          Token.Integer x -> Just (x, Located.origin token)
          _ -> Nothing
      )
  let go 0 = [Word () "zero" [] origin]
      go n = go (n - 1) ++ [Word () "succ" [] origin]

  pure $ compose () origin (go num)

sectionParser :: Parser (Term ())
sectionParser =
  (<?> "operator section") $
    groupedParser $
      Parsec.choice
        [ do
            origin <- getTokenOrigin
            function <- operatorNameParser
            let call =
                  Word
                    ()
                    (UnqualifiedName function)
                    []
                    origin
            Parsec.choice
              [ do
                  operandOrigin <- getTokenOrigin
                  operand <- Parsec.many1 termParser
                  pure $ compose () operandOrigin $ operand ++ [call],
                pure call
              ],
          do
            operandOrigin <- getTokenOrigin
            operand <-
              Parsec.many1 $
                Parsec.notFollowedBy operatorNameParser *> termParser
            origin <- getTokenOrigin
            function <- operatorNameParser
            pure $
              compose () operandOrigin $
                operand
                  ++ [ Word
                         ()
                         (QualifiedName (Qualified Vocabulary.intrinsic "swap"))
                         []
                         origin,
                       Word () (UnqualifiedName function) [] origin
                     ]
        ]

vectorParser :: Parser (Term ())
vectorParser = (<?> "list literal") $ do
  origin <- getTokenOrigin
  es <- bracketedParser $ (compose () origin <$> Parsec.many1 termParser) `Parsec.sepEndBy` commaParser
  pure $ compose () origin ((Group <$> es) ++ [Word () "nil" [] origin] ++ replicate (length es) (Word () "cons" [] origin))

lambdaParser :: Parser (Term ())
lambdaParser = (<?> "parameteriable introduction") $ do
  names <- parserMatch Token.Arrow *> lambdaNamesParser
  Parsec.choice
    [ parserMatchOperator ";" *> do
        origin <- getTokenOrigin
        body <- blockContentsParser
        pure $ makeLambda names body origin,
      do
        origin <- getTokenOrigin
        body <- blockParser
        pure $ Push () (Quotation $ makeLambda names body origin) origin
    ]

matchParser :: Parser (Term ())
matchParser = (<?> "match") $ do
  matchOrigin <- getTokenOrigin <* parserMatch Token.Match
  scrutineeOrigin <- getTokenOrigin
  mScrutinee <- Parsec.optionMaybe groupParser <?> "scrutinee"
  (cases, else_) <- do
    cases' <-
      many $
        (<?> "case") $
          parserMatch Token.Case *> do
            origin <- getTokenOrigin
            name <- nameParser
            body <- blockLikeParser
            pure $ Case name body origin
    mElse' <- Parsec.optionMaybe $ do
      origin <- getTokenOrigin <* parserMatch Token.Else
      body <- blockParser
      pure $ Else body origin
    pure $
      (,) cases' $
        fromMaybe
          (DefaultElse () matchOrigin)
          mElse'
  let match = Match AnyMatch () cases else_ matchOrigin
  pure $ case mScrutinee of
    Just scrutinee -> compose () scrutineeOrigin [scrutinee, match]
    Nothing -> match

ifParser :: Parser (Term ())
ifParser = (<?> "if-else expression") $ do
  ifOrigin <- getTokenOrigin <* parserMatch Token.If
  mCondition <- Parsec.optionMaybe groupParser <?> "condition"
  ifBody <- blockParser
  elseBody <-
    Parsec.option (Term.identityCoercion () ifOrigin) $
      parserMatch Token.Else *> blockParser
  pure $
    compose
      ()
      ifOrigin
      [ fromMaybe (Term.identityCoercion () ifOrigin) mCondition,
        Match
          BooleanMatch
          ()
          [ Case "true" ifBody ifOrigin,
            Case "false" elseBody (Term.origin elseBody)
          ]
          (DefaultElse () ifOrigin)
          ifOrigin
      ]

doParser :: Parser (Term ())
doParser = (<?> "do expression") $ do
  doOrigin <- getTokenOrigin <* parserMatch Token.Do
  term <- groupParser <?> "parenthesized expression"
  Parsec.choice
    -- do (f) { x y z } => { x y z } f
    [ do
        body <- blockLikeParser
        pure $
          compose
            ()
            doOrigin
            [Push () (Quotation body) (Term.origin body), term],
      -- do (f) [x, y, z] => [x, y, z] f
      do
        body <- vectorParser
        pure $ compose () doOrigin [body, term]
    ]

blockValue :: Parser (Value ())
blockValue = (<?> "quotation") $ Quotation <$> blockParser

asParser :: Parser (Term ())
asParser = (<?> "'as' expression") $ do
  origin <- getTokenOrigin <* parserMatch_ Token.As
  signatures <- groupedParser $ basicTypeParser `Parsec.sepEndBy` commaParser
  pure $ Term.asCoercion () origin signatures

-- A 'with' term is parsed as a coercion followed by a call.
withParser :: Parser (Term ())
withParser = (<?> "'with' expression") $ do
  origin <- getTokenOrigin <* parserMatch_ Token.With
  permits <- groupedParser $ Parsec.many1 permitParser
  pure $
    Term.compose
      ()
      origin
      [ Term.permissionCoercion permits () origin,
        Word
          ()
          (QualifiedName (Qualified Vocabulary.intrinsic "call"))
          []
          origin
      ]

permitParser :: Parser Term.Permit
permitParser =
  Term.Permit
    <$> Parsec.choice
      [ True <$ parserMatchOperator "+",
        False <$ parserMatchOperator "-"
      ]
    <*> (UnqualifiedName <$> lowerNameParser)

parserMatchOperator :: Text -> Parser (Located Token)
parserMatchOperator = parserMatch . Token.Operator . Unqualified

lambdaNamesParser :: Parser [(Maybe Unqualified, Origin)]
lambdaNamesParser = lambdaName `Parsec.sepEndBy1` commaParser

lambdaName :: Parser (Maybe Unqualified, Origin)
lambdaName = do
  origin <- getTokenOrigin
  name <- Just <$> lowerNameParser <|> Nothing <$ parserMatch Token.Ignore
  pure (name, origin)

blockLikeParser :: Parser (Term ())
blockLikeParser =
  Parsec.choice
    [ blockParser,
      parserMatch Token.Arrow *> do
        names <- lambdaNamesParser
        origin <- getTokenOrigin
        body <- blockParser
        pure $ makeLambda names body origin
    ]

makeLambda :: [(Maybe Unqualified, Origin)] -> Term () -> Origin -> Term ()
makeLambda parsed body origin =
  foldr
    ( \(nameMaybe, nameOrigin) acc ->
        maybe
          ( Compose
              ()
              ( Word
                  ()
                  (QualifiedName (Qualified Vocabulary.intrinsic "drop"))
                  []
                  origin
              )
              acc
          )
          (\name -> Lambda () name () acc nameOrigin)
          nameMaybe
    )
    body
    (reverse parsed)
