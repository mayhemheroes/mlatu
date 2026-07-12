//! Authored known-answer oracle for mlatu_lib (mlatu-lang/libraries), the language
//! library the upstream mlatu CLI wraps and the `parse` fuzz target drives.
//! Upstream mlatu-lang/mlatu ships no test suite of its own, so these tests pin the
//! observable behavior of the library's parse / pretty / rewrite code paths with
//! concrete expected values (golden strings and structural assertions).

#[cfg(test)]
mod tests {
    use im::vector;
    use mlatu_lib::{parse, pretty, rewrite, Engine, Primitive, Rule, Term};

    fn round_trips(engine: &Engine, input: &str, expected: &str) {
        let terms = parse::terms(engine, input).unwrap();
        assert_eq!(pretty::terms(engine, terms), expected.to_owned());
    }

    fn rewrites_to(engine: &Engine, rules: im::Vector<Rule>, begin: &str, end: &str) {
        let begin_terms = parse::terms(engine, begin).unwrap();
        let rewritten = rewrite(engine, &rules, begin_terms);
        assert_eq!(pretty::terms(engine, rewritten), end.to_owned());
    }

    #[test]
    fn parse_terms_structure() {
        let engine = Engine::new();
        let terms = parse::terms(&engine, "a b c").unwrap();
        assert_eq!(terms.len(), 3);
        assert!(matches!(terms[0], Term::Word(_)));
        let quoted = parse::terms(&engine, "(a b) c").unwrap();
        assert_eq!(quoted.len(), 2);
        match &quoted[0] {
            Term::Quote(inner) => assert_eq!(inner.len(), 2),
            other => panic!("expected quote, got {other:?}"),
        }
    }

    #[test]
    fn parse_primitives() {
        let engine = Engine::new();
        let terms = parse::terms(&engine, "+ - ~ , < >").unwrap();
        let prims: Vec<_> = terms
            .iter()
            .map(|t| match t {
                Term::Prim(p) => p.clone(),
                other => panic!("expected primitive, got {other:?}"),
            })
            .collect();
        assert_eq!(
            prims,
            vec![
                Primitive::Copy,
                Primitive::Discard,
                Primitive::Swap,
                Primitive::Combine,
                Primitive::Unwrap,
                Primitive::Wrap
            ]
        );
    }

    #[test]
    fn parse_pretty_round_trip() {
        let engine = Engine::new();
        round_trips(&engine, "a b c", "a b c");
        round_trips(&engine, "(a  b)   c", "(a b) c");
        round_trips(&engine, "((a) b) (c)", "((a) b) (c)");
        round_trips(&engine, "(x) + ~", "(x) + ~");
    }

    #[test]
    fn parse_rejects_invalid() {
        let engine = Engine::new();
        assert!(parse::terms(&engine, "(a").is_err());
        assert!(parse::terms(&engine, "a)").is_err());
        assert!(parse::term(&engine, "a b").is_err());
        assert!(parse::rule(&engine, "a = b").is_err()); // missing final period
    }

    #[test]
    fn parse_rules_known_answer() {
        let engine = Engine::new();
        let rules = parse::rules(&engine, "x = y . a b = c .").unwrap();
        assert_eq!(rules.len(), 2);
        assert_eq!(pretty::rule(&engine, rules[0].clone()), "x = y.");
        assert_eq!(pretty::rule(&engine, rules[1].clone()), "a b = c.");
        assert_eq!(rules[1].redex.len(), 2);
        assert_eq!(rules[1].reduction.len(), 1);
    }

    #[test]
    fn rewrite_copy() {
        let engine = Engine::new();
        rewrites_to(&engine, vector![], "(x) +", "(x) (x)");
        rewrites_to(&engine, vector![], "(x) (y) + (z)", "(x) (y) (y) (z)");
        rewrites_to(&engine, vector![], "x +", "x +");
    }

    #[test]
    fn rewrite_swap() {
        let engine = Engine::new();
        rewrites_to(&engine, vector![], "(x) (y) ~", "(y) (x)");
        rewrites_to(&engine, vector![], "(x) (y) ~ (z)", "(y) (x) (z)");
        rewrites_to(&engine, vector![], "(x) ~", "(x) ~");
    }

    #[test]
    fn rewrite_combine() {
        let engine = Engine::new();
        rewrites_to(&engine, vector![], "(x) (y) ,", "(x y)");
        rewrites_to(&engine, vector![], "(a b) (c) ,", "(a b c)");
    }

    #[test]
    fn rewrite_wrap_unwrap_discard() {
        let engine = Engine::new();
        rewrites_to(&engine, vector![], "(x) >", "((x))");
        rewrites_to(&engine, vector![], "(a b) <", "a b");
        rewrites_to(&engine, vector![], "(x) - y", "y");
    }

    #[test]
    fn rewrite_user_rules() {
        let engine = Engine::new();
        let rules = parse::rules(&engine, "x = y y .").unwrap();
        rewrites_to(&engine, rules.clone(), "a x b", "a y y b");
        let dup = parse::rules(&engine, "dup = + .").unwrap();
        rewrites_to(&engine, dup, "(q) dup", "(q) (q)");
    }
}
