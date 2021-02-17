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

import Data.HashMap.Strict qualified as HashMap
import Data.List (findIndex)
import Data.Text qualified as Text
import Mlatu.Bracket (bracket)
import Mlatu.DataConstructor (DataConstructor (DataConstructor))
import Mlatu.DataConstructor qualified as DataConstructor
import Mlatu.Declaration (Declaration (Declaration))
import Mlatu.Declaration qualified as Declaration
import Mlatu.Definition (Definition (Definition))
import Mlatu.Definition qualified as Definition
import Mlatu.Desugar.Data qualified as Data
import Mlatu.Element (Element)
import Mlatu.Element qualified as Element
import Mlatu.Entry.Category (Category)
import Mlatu.Entry.Category qualified as Category
import Mlatu.Entry.Merge qualified as Merge
import Mlatu.Entry.Parameter (Parameter (Parameter))
import Mlatu.Entry.Parent qualified as Parent
import Mlatu.Fragment (Fragment (Fragment))
import Mlatu.Fragment qualified as Fragment
import Mlatu.Informer (Informer (..), errorCheckpoint)
import Mlatu.Kind (Kind (..))
import Mlatu.Layoutness (Layoutness (..))
import Mlatu.Located (Located)
import Mlatu.Located qualified as Located
import Mlatu.Metadata (Metadata (Metadata))
import Mlatu.Metadata qualified as Metadata
import Mlatu.Monad (K)
import Mlatu.Name
  ( GeneralName (..),
    Qualified (Qualified),
    Qualifier (Qualifier),
    Root (Absolute, Relative),
    Unqualified (..),
  )
import Mlatu.Operator qualified as Operator
import Mlatu.Origin (Origin)
import Mlatu.Origin qualified as Origin
import Mlatu.Parser (Parser, getTokenOrigin, parserMatch, parserMatch_)
import Mlatu.Report qualified as Report
import Mlatu.Signature (Signature)
import Mlatu.Signature qualified as Signature
import Mlatu.Synonym (Synonym (Synonym))
import Mlatu.Term (Case (..), Else (..), MatchHint (..), Term (..), Value (..), compose)
import Mlatu.Term qualified as Term
import Mlatu.Token (Token)
import Mlatu.Token qualified as Token
import Mlatu.Tokenize (tokenize)
import Mlatu.TypeDefinition (TypeDefinition (TypeDefinition))
import Mlatu.TypeDefinition qualified as TypeDefinition
import Mlatu.Vocabulary qualified as Vocabulary
import Relude hiding (Compose)
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
  [Located (Token 'Nonlayout)] ->
  -- | Parsed program fragment.
  K (Fragment ())
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
        Right result -> return (Data.desugar (insertMain result))
  where
    isMain = (fromMaybe Definition.mainName mainName ==) . Definition.name
    insertMain f = case find isMain $ Fragment.definitions f of
      Just {} -> f
      Nothing ->
        f
          { Fragment.definitions =
              Definition.main
                mainPermissions
                mainName
                (Term.identityCoercion () (Origin.point path line 1)) :
              Fragment.definitions f
          }

-- | Parses only a name.
generalName :: (Informer m) => Int -> FilePath -> Text -> m GeneralName
generalName line path text = do
  tokens <- tokenize line path text
  errorCheckpoint
  bracketed <- bracket path tokens
  let parsed = Parsec.runParser nameParser Vocabulary.global path bracketed
  case parsed of
    Left parseError -> do
      report $ Report.parseError parseError
      halt
    Right (name, _) -> return name

fragmentParser ::
  [GeneralName] -> Maybe Qualified -> Parser (Fragment ())
fragmentParser mainPermissions mainName =
  partitionElements mainPermissions mainName
    <$> elementsParser <* Parsec.eof

elementsParser :: Parser [Element ()]
elementsParser = concat <$> many (vocabularyParser <|> one <$> elementParser)

partitionElements ::
  [GeneralName] ->
  Maybe Qualified ->
  [Element ()] ->
  Fragment ()
partitionElements mainPermissions mainName = rev . foldr go mempty
  where
    rev :: Fragment () -> Fragment ()
    rev f =
      Fragment
        { Fragment.declarations = reverse $ Fragment.declarations f,
          Fragment.definitions = reverse $ Fragment.definitions f,
          Fragment.metadata = reverse $ Fragment.metadata f,
          Fragment.synonyms = reverse $ Fragment.synonyms f,
          Fragment.types = reverse $ Fragment.types f
        }

    go :: Element () -> Fragment () -> Fragment ()
    go element acc = case element of
      Element.Declaration x ->
        acc
          { Fragment.declarations = x : Fragment.declarations acc
          }
      Element.Definition x ->
        acc
          { Fragment.definitions = x : Fragment.definitions acc
          }
      Element.Metadata x ->
        acc
          { Fragment.metadata = x : Fragment.metadata acc
          }
      Element.Synonym x ->
        acc
          { Fragment.synonyms = x : Fragment.synonyms acc
          }
      Element.TypeDefinition x ->
        acc
          { Fragment.types = x : Fragment.types acc
          }
      Element.Term x ->
        acc
          { Fragment.definitions =
              case findIndex
                ((== fromMaybe Definition.mainName mainName) . Definition.name)
                $ Fragment.definitions acc of
                Just index -> case splitAt index $ Fragment.definitions acc of
                  (a, existing : b) ->
                    a
                      ++ existing
                        { Definition.body =
                            composeUnderLambda (Definition.body existing) x
                        } :
                    b
                  _nonMain -> error "cannot find main definition"
                Nothing ->
                  Definition.main mainPermissions mainName x :
                  Fragment.definitions acc
          }
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

vocabularyParser :: Parser [Element ()]
vocabularyParser = (<?> "vocabulary definition") $ do
  parserMatch_ Token.Vocab
  original@(Qualifier _ outer) <- Parsec.getState
  (vocabularyName, _) <- nameParser
  let (inner, name) = case vocabularyName of
        QualifiedName
          (Qualified (Qualifier _root qualifier) (Unqualified unqualified)) ->
            (qualifier, unqualified)
        UnqualifiedName (Unqualified unqualified) -> ([], unqualified)
        LocalName {} -> error "local name should not appear as vocabulary name"
  Parsec.putState (Qualifier Absolute (outer ++ inner ++ [name]))
  Parsec.choice
    [ [] <$ parserMatchOperator ";",
      do
        elements <- blockedParser elementsParser
        Parsec.putState original
        return elements
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

-- See note [Angle Brackets].

bracketedParser :: Parser a -> Parser a
bracketedParser =
  Parsec.between
    (parserMatch Token.VectorBegin)
    (parserMatch Token.VectorEnd)

nameParser :: Parser (GeneralName, Operator.Fixity)
nameParser = (<?> "name") $ do
  global <-
    isJust
      <$> Parsec.optionMaybe
        (parserMatch Token.Ignore <* parserMatch Token.VocabLookup)
  parts <-
    Parsec.choice
      [ (,) Operator.Postfix <$> wordNameParser,
        (,) Operator.Infix <$> operatorNameParser
      ]
      `Parsec.sepBy1` parserMatch Token.VocabLookup
  return $ case parts of
    [(fixity, unqualified)] ->
      ( ( if global
            then QualifiedName . Qualified Vocabulary.global
            else UnqualifiedName
        )
          unqualified,
        fixity
      )
    _list ->
      let parts' = map ((\(Unqualified part) -> part) . snd) parts
          qualifier = Unsafe.fromJust (viaNonEmpty init parts')
          (fixity, unqualified) = Unsafe.fromJust (viaNonEmpty last parts)
       in ( QualifiedName
              ( Qualified
                  (Qualifier (if global then Absolute else Relative) qualifier)
                  unqualified
              ),
            fixity
          )

unqualifiedNameParser :: Parser Unqualified
unqualifiedNameParser =
  (<?> "unqualified name") $
    wordNameParser <|> operatorNameParser

wordNameParser :: Parser Unqualified
wordNameParser = (<?> "word name") $
  parseOne $
    \token -> case Located.item token of
      Token.Word name -> Just name
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
  return $ Unqualified $ Text.concat $ angles ++ [rest]

parseOne :: (Located (Token 'Nonlayout) -> Maybe a) -> Parser a
parseOne = Parsec.tokenPrim show advance
  where
    advance :: SourcePos -> t -> [Located (Token 'Nonlayout)] -> SourcePos
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
        Element.Metadata <$> metadataParser,
        Element.Synonym <$> synonymParser,
        Element.TypeDefinition <$> typeDefinitionParser,
        do
          origin <- getTokenOrigin
          Element.Term . compose () origin <$> Parsec.many1 termParser
      ]

synonymParser :: Parser Synonym
synonymParser = (<?> "synonym definition") $ do
  origin <- getTokenOrigin <* parserMatch_ Token.Synonym
  from <-
    Qualified <$> Parsec.getState
      <*> unqualifiedNameParser
  (to, _) <- nameParser
  return $ Synonym from to origin

metadataParser :: Parser Metadata
metadataParser = (<?> "metadata block") $ do
  origin <- getTokenOrigin <* parserMatch Token.About
  -- FIXME: This only allows metadata to be defined for elements within the
  -- current vocabulary.
  name <-
    Qualified <$> Parsec.getState
      <*> Parsec.choice
        [ unqualifiedNameParser <?> "word identifier",
          (parserMatch Token.Type *> wordNameParser)
            <?> "'type' and type identifier"
        ]
  fields <-
    blockedParser $
      many $
        (,)
          <$> (wordNameParser <?> "metadata key identifier")
          <*> (blockParser <?> "metadata value block")
  return
    Metadata
      { Metadata.fields = HashMap.fromList fields,
        Metadata.name = QualifiedName name,
        Metadata.origin = origin
      }

typeDefinitionParser :: Parser TypeDefinition
typeDefinitionParser = (<?> "type definition") $ do
  origin <- getTokenOrigin <* parserMatch Token.Type
  (name, fixity) <- qualifiedNameParser <?> "type definition name"
  case fixity of
    Operator.Infix -> Parsec.unexpected "type-level operator"
    Operator.Postfix -> pass
  parameters <- Parsec.option [] quantifierParser
  constructors <- blockedParser (many constructorParser)
  return
    TypeDefinition
      { TypeDefinition.constructors = constructors,
        TypeDefinition.name = name,
        TypeDefinition.origin = origin,
        TypeDefinition.parameters = parameters
      }

constructorParser :: Parser DataConstructor
constructorParser = (<?> "constructor definition") $ do
  origin <- getTokenOrigin <* parserMatch Token.Case
  name <- wordNameParser <?> "constructor name"
  fields <-
    (<?> "constructor fields") $
      Parsec.option [] $
        groupedParser constructorFieldsParser
  return
    DataConstructor
      { DataConstructor.fields = fields,
        DataConstructor.name = name,
        DataConstructor.origin = origin
      }

constructorFieldsParser :: Parser [Signature]
constructorFieldsParser = typeParser `Parsec.sepEndBy` commaParser

typeParser :: Parser Signature
typeParser = Parsec.try functionTypeParser <|> basicTypeParser <?> "type"

functionTypeParser :: Parser Signature
functionTypeParser = (<?> "function type") $ do
  (effect, origin) <-
    Parsec.choice
      [ stackSignature,
        arrowSignature
      ]
  perms <- permissions
  return (effect perms origin)
  where
    stackSignature :: Parser ([GeneralName] -> Origin -> Signature, Origin)
    stackSignature = (<?> "stack function type") $ do
      leftparameter <- UnqualifiedName <$> stack
      leftTypes <- Parsec.option [] (commaParser *> left)
      origin <- arrow
      rightparameter <- UnqualifiedName <$> stack
      rightTypes <- Parsec.option [] (commaParser *> right)
      return
        ( Signature.StackFunction
            (Signature.Variable leftparameter origin)
            leftTypes
            (Signature.Variable rightparameter origin)
            rightTypes,
          origin
        )
      where
        stack :: Parser Unqualified
        stack = Parsec.try $ wordNameParser <* parserMatch Token.Ellipsis

    arrowSignature :: Parser ([GeneralName] -> Origin -> Signature, Origin)
    arrowSignature = (<?> "arrow function type") $ do
      leftTypes <- left
      origin <- arrow
      rightTypes <- right
      return (Signature.Function leftTypes rightTypes, origin)

    permissions :: Parser [GeneralName]
    permissions =
      (<?> "permission labels") $
        many $ parserMatchOperator "+" *> (fst <$> nameParser)

    left, right :: Parser [Signature]
    left = basicTypeParser `Parsec.sepEndBy` commaParser
    right = typeParser `Parsec.sepEndBy` commaParser

    arrow :: Parser Origin
    arrow = getTokenOrigin <* parserMatch Token.Arrow

commaParser :: Parser ()
commaParser = void $ parserMatch Token.Comma

basicTypeParser :: Parser Signature
basicTypeParser = (<?> "basic type") $ do
  prefix <-
    Parsec.choice
      [ quantifiedParser $ groupedParser typeParser,
        Parsec.try $ do
          origin <- getTokenOrigin
          (name, fixity) <- nameParser
          -- Must be a word, not an operator, but may be qualified.
          guard $ fixity == Operator.Postfix
          return $ Signature.Variable name origin,
        groupedParser typeParser
      ]
  let apply a b = Signature.Application a b $ Signature.origin prefix
  mSuffix <-
    Parsec.optionMaybe $
      fmap concat $
        Parsec.many1 $ typeListParser basicTypeParser
  return $ case mSuffix of
    Just suffix -> foldl' apply prefix suffix
    Nothing -> prefix

quantifierParser :: Parser [Parameter]
quantifierParser = typeListParser parameter

parameter :: Parser Parameter
parameter = do
  Parsec.choice
    [ permissionParameter,
      Parsec.try stackParameter,
      valueParameter
    ]

permissionParameter :: Parser Parameter
permissionParameter = do
  origin <- getTokenOrigin
  _ <- parserMatchOperator "+"
  (\unqualified -> Parameter origin unqualified Permission) <$> wordNameParser

stackParameter :: Parser Parameter
stackParameter = do
  origin <- getTokenOrigin
  (\name -> Parameter origin name Stack) <$> (wordNameParser <* parserMatch Token.Ellipsis)

valueParameter :: Parser Parameter
valueParameter = do
  origin <- getTokenOrigin
  (\name -> Parameter origin name Value) <$> wordNameParser

typeListParser :: Parser a -> Parser [a]
typeListParser element =
  bracketedParser $
    element `Parsec.sepEndBy1` commaParser

quantifiedParser :: Parser Signature -> Parser Signature
quantifiedParser thing = do
  origin <- getTokenOrigin
  Signature.Quantified <$> quantifierParser <*> thing <*> pure origin

traitParser :: Parser Declaration
traitParser =
  (<?> "intrinsic declaration") $
    declarationParser Token.Trait Declaration.Trait

intrinsicParser :: Parser Declaration
intrinsicParser =
  (<?> "intrinsic declaration") $
    declarationParser Token.Intrinsic Declaration.Intrinsic

declarationParser ::
  Token 'Nonlayout ->
  Declaration.Category ->
  Parser Declaration
declarationParser keyword category = do
  origin <- getTokenOrigin <* parserMatch keyword
  suffix <- unqualifiedNameParser <?> "declaration name"
  name <- Qualified <$> Parsec.getState <*> pure suffix
  sig <- signatureParser
  return
    Declaration
      { Declaration.category = category,
        Declaration.name = name,
        Declaration.origin = origin,
        Declaration.signature = sig
      }

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
qualifiedNameParser :: Parser (Qualified, Operator.Fixity)
qualifiedNameParser = (<?> "optionally qualified name") $ do
  (suffix, fixity) <- nameParser
  name <- case suffix of
    QualifiedName qualified@(Qualified (Qualifier root parts) unqualified) ->
      case root of
        -- Fully qualified name: return it as-is.
        Absolute -> pure qualified
        -- Partially qualified name: add current vocab prefix to qualifier.
        Relative -> do
          Qualifier root' prefixParts <- Parsec.getState
          pure (Qualified (Qualifier root' (prefixParts ++ parts)) unqualified)
    -- Unqualified name: use current vocab prefix as qualifier.
    UnqualifiedName unqualified ->
      Qualified <$> Parsec.getState <*> pure unqualified
    LocalName _ -> error "name parser should only return qualified or unqualified name"
  pure (name, fixity)

definitionParser :: Token 'Nonlayout -> Category -> Parser (Definition ())
definitionParser keyword category = do
  origin <- getTokenOrigin <* parserMatch keyword
  (name, fixity) <- qualifiedNameParser <?> "definition name"
  sig <- signatureParser
  body <- blockLikeParser <?> "definition body"
  return
    Definition
      { Definition.body = body,
        Definition.category = category,
        Definition.fixity = fixity,
        Definition.inferSignature = False,
        Definition.merge = Merge.Deny,
        Definition.name = name,
        Definition.origin = origin,
        -- HACK: Should be passed in from outside?
        Definition.parent = case keyword of
          Token.Instance -> Just $ Parent.Type name
          _nonInstance -> Nothing,
        Definition.signature = sig
      }

signatureParser :: Parser Signature
signatureParser = quantifiedParser signature <|> signature <?> "type signature"

signature :: Parser Signature
signature = groupedParser functionTypeParser

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
          Word () Operator.Postfix
            <$> (fst <$> nameParser) <*> pure [] <*> pure origin,
        termParser
      ]

blockContentsParser :: Parser (Term ())
blockContentsParser = do
  origin <- getTokenOrigin
  terms <- many termParser
  let origin' = case terms of
        x : _ -> Term.origin x
        _emptyList -> origin
  return $ foldr (Compose ()) (Term.identityCoercion () origin') terms

termParser :: Parser (Term ())
termParser = (<?> "expression") $ do
  origin <- getTokenOrigin
  Parsec.choice
    [ Parsec.try (uncurry (Push ()) <$> parseOne toLiteral <?> "literal"),
      do
        (name, fixity) <- nameParser
        return (Word () fixity name [] origin),
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

toLiteral :: Located (Token 'Nonlayout) -> Maybe (Value (), Origin)
toLiteral token = case Located.item token of
  Token.Character x -> Just (Character x, origin)
  Token.Float x -> Just (Float x, origin)
  Token.Integer x -> Just (Integer x, origin)
  Token.Text x -> Just (Text x, origin)
  _nonLiteral -> Nothing
  where
    origin :: Origin
    origin = Located.origin token

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
                    Operator.Postfix
                    (UnqualifiedName function)
                    []
                    origin
            Parsec.choice
              [ do
                  operandOrigin <- getTokenOrigin
                  operand <- Parsec.many1 termParser
                  return $ compose () operandOrigin $ operand ++ [call],
                return call
              ],
          do
            operandOrigin <- getTokenOrigin
            operand <-
              Parsec.many1 $
                Parsec.notFollowedBy operatorNameParser *> termParser
            origin <- getTokenOrigin
            function <- operatorNameParser
            return $
              compose () operandOrigin $
                operand
                  ++ [ Word
                         ()
                         Operator.Postfix
                         (QualifiedName (Qualified Vocabulary.intrinsic "swap"))
                         []
                         origin,
                       Word () Operator.Postfix (UnqualifiedName function) [] origin
                     ]
        ]

vectorParser :: Parser (Term ())
vectorParser = (<?> "vector literal") $ do
  vectorOrigin <- getTokenOrigin
  elements <-
    bracketedParser $
      (compose () vectorOrigin <$> Parsec.many1 termParser)
        `Parsec.sepEndBy` commaParser
  return $
    compose () vectorOrigin $
      map Group elements
        ++ [NewVector () (length elements) () vectorOrigin]

lambdaParser :: Parser (Term ())
lambdaParser = (<?> "parameteriable introduction") $ do
  names <- parserMatch Token.Arrow *> lambdaNamesParser
  Parsec.choice
    [ parserMatchOperator ";" *> do
        origin <- getTokenOrigin
        body <- blockContentsParser
        return $ makeLambda names body origin,
      do
        origin <- getTokenOrigin
        body <- blockParser
        return $ Push () (Quotation $ makeLambda names body origin) origin
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
            (name, _) <- nameParser
            body <- blockLikeParser
            return $ Case name body origin
    mElse' <- Parsec.optionMaybe $ do
      origin <- getTokenOrigin <* parserMatch Token.Else
      body <- blockParser
      return $ Else body origin
    return $
      (,) cases' $
        fromMaybe
          (Else (defaultMatchElse matchOrigin) matchOrigin)
          mElse'
  let match = Match AnyMatch () cases else_ matchOrigin
  return $ case mScrutinee of
    Just scrutinee -> compose () scrutineeOrigin [scrutinee, match]
    Nothing -> match

defaultMatchElse :: Origin -> Term ()
defaultMatchElse =
  Word
    ()
    Operator.Postfix
    (QualifiedName (Qualified Vocabulary.global "abort"))
    []

ifParser :: Parser (Term ())
ifParser = (<?> "if-else expression") $ do
  ifOrigin <- getTokenOrigin <* parserMatch Token.If
  mCondition <- Parsec.optionMaybe groupParser <?> "condition"
  ifBody <- blockParser
  elifs <- many $ do
    origin <- getTokenOrigin <* parserMatch Token.Elif
    condition <- groupParser <?> "condition"
    body <- blockParser
    return (condition, body, origin)
  elseBody <-
    Parsec.option (Term.identityCoercion () ifOrigin) $
      parserMatch Token.Else *> blockParser
  let desugarCondition :: (Term (), Term (), Origin) -> Term () -> Term ()
      desugarCondition (condition, body, origin) acc =
        let match =
              Match
                BooleanMatch
                ()
                [ Case "true" body origin,
                  Case "false" acc (Term.origin acc)
                ]
                (Else (defaultMatchElse ifOrigin) ifOrigin)
                origin
         in compose () ifOrigin [condition, match]
  return $
    foldr desugarCondition elseBody $
      ( fromMaybe (Term.identityCoercion () ifOrigin) mCondition,
        ifBody,
        ifOrigin
      ) :
      elifs

doParser :: Parser (Term ())
doParser = (<?> "do expression") $ do
  doOrigin <- getTokenOrigin <* parserMatch Token.Do
  term <- groupParser <?> "parenthesized expression"
  Parsec.choice
    -- do (f) { x y z } => { x y z } f
    [ do
        body <- blockLikeParser
        return $
          compose
            ()
            doOrigin
            [Push () (Quotation body) (Term.origin body), term],
      -- do (f) [x, y, z] => [x, y, z] f
      do
        body <- vectorParser
        return $ compose () doOrigin [body, term]
    ]

blockValue :: Parser (Value ())
blockValue = (<?> "quotation") $ Quotation <$> blockParser

asParser :: Parser (Term ())
asParser = (<?> "'as' expression") $ do
  origin <- getTokenOrigin <* parserMatch_ Token.As
  signatures <- groupedParser $ basicTypeParser `Parsec.sepEndBy` commaParser
  return $ Term.asCoercion () origin signatures

-- A 'with' term is parsed as a coercion followed by a call.
withParser :: Parser (Term ())
withParser = (<?> "'with' expression") $ do
  origin <- getTokenOrigin <* parserMatch_ Token.With
  permits <- groupedParser $ Parsec.many1 permitParser
  return $
    Term.compose
      ()
      origin
      [ Term.permissionCoercion permits () origin,
        Word
          ()
          Operator.Postfix
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
    <*> (UnqualifiedName <$> wordNameParser)

parserMatchOperator :: Text -> Parser (Located (Token 'Nonlayout))
parserMatchOperator = parserMatch . Token.Operator . Unqualified

lambdaNamesParser :: Parser [(Maybe Unqualified, Origin)]
lambdaNamesParser = lambdaName `Parsec.sepEndBy1` commaParser

lambdaName :: Parser (Maybe Unqualified, Origin)
lambdaName = do
  origin <- getTokenOrigin
  name <- Just <$> wordNameParser <|> Nothing <$ parserMatch Token.Ignore
  return (name, origin)

blockLikeParser :: Parser (Term ())
blockLikeParser =
  Parsec.choice
    [ blockParser,
      parserMatch Token.Arrow *> do
        names <- lambdaNamesParser
        origin <- getTokenOrigin
        body <- blockParser
        return $ makeLambda names body origin
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
                  Operator.Postfix
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
