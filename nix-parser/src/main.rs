// nisp-nix-parser — tiny shim over rnix-parser.
//
// Reads a Nix source file from stdin (or a path arg), parses with rnix,
// emits the AST as JSON on stdout. The Racket-side nisp-import consumes
// this JSON and translates it to nisp source.
//
// JSON schema: every node is `{ "kind": "...", ...fields }`. Position
// info (line/col) is included on every node for downstream error
// reporting.

use std::io::{self, Read};
use rnix::ast::{self, HasEntry};
use rowan::ast::{AstChildren, AstNode};
use rnix::ast::AstToken;
use serde::Serialize;
use serde_json::{json, Value};

#[derive(Serialize)]
struct Output {
    ast: Value,
    errors: Vec<String>,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let source = if args.len() >= 2 {
        std::fs::read_to_string(&args[1]).expect("can't read file")
    } else {
        let mut s = String::new();
        io::stdin().read_to_string(&mut s).expect("stdin read failed");
        s
    };

    let parse = rnix::Root::parse(&source);
    let errors: Vec<String> = parse.errors().iter().map(|e| e.to_string()).collect();
    let root = parse.tree();
    let ast = root.expr().map(|e| expr_to_json(&e)).unwrap_or(Value::Null);

    let out = Output { ast, errors };
    println!("{}", serde_json::to_string(&out).unwrap());
}

fn pos_of<N: AstNode>(node: &N) -> Value {
    let range = node.syntax().text_range();
    json!({
        "start": usize::from(range.start()),
        "end": usize::from(range.end()),
    })
}

fn expr_to_json(e: &ast::Expr) -> Value {
    match e {
        ast::Expr::Apply(n) => json!({
            "kind": "Apply",
            "fn": n.lambda().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "arg": n.argument().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "pos": pos_of(n),
        }),
        ast::Expr::Assert(n) => json!({
            "kind": "Assert",
            "cond": n.condition().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "body": n.body().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "pos": pos_of(n),
        }),
        ast::Expr::AttrSet(n) => {
            let recursive = n.rec_token().is_some();
            json!({
                "kind": "AttrSet",
                "recursive": recursive,
                "entries": entries_to_json(n.entries()),
                "pos": pos_of(n),
            })
        }
        ast::Expr::BinOp(n) => json!({
            "kind": "BinOp",
            "op": binop_kind(n),
            "lhs": n.lhs().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "rhs": n.rhs().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "pos": pos_of(n),
        }),
        ast::Expr::Error(n) => json!({
            "kind": "Error",
            "pos": pos_of(n),
        }),
        ast::Expr::HasAttr(n) => json!({
            "kind": "HasAttr",
            "expr": n.expr().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "attrpath": n.attrpath().map(attrpath_to_json).unwrap_or(json!([])),
            "pos": pos_of(n),
        }),
        ast::Expr::Ident(n) => json!({
            "kind": "Ident",
            "name": n.ident_token().map(|t| t.text().to_string()).unwrap_or_default(),
            "pos": pos_of(n),
        }),
        ast::Expr::IfElse(n) => json!({
            "kind": "IfElse",
            "cond": n.condition().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "then": n.body().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "else": n.else_body().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "pos": pos_of(n),
        }),
        ast::Expr::Lambda(n) => {
            let param = n.param().map(param_to_json).unwrap_or(Value::Null);
            json!({
                "kind": "Lambda",
                "param": param,
                "body": n.body().as_ref().map(expr_to_json).unwrap_or(Value::Null),
                "pos": pos_of(n),
            })
        }
        ast::Expr::LegacyLet(n) => json!({
            "kind": "LegacyLet",
            "entries": entries_to_json(n.entries()),
            "pos": pos_of(n),
        }),
        ast::Expr::LetIn(n) => json!({
            "kind": "LetIn",
            "entries": entries_to_json(n.entries()),
            "body": n.body().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "pos": pos_of(n),
        }),
        ast::Expr::List(n) => json!({
            "kind": "List",
            "items": n.items().map(|i| expr_to_json(&i)).collect::<Vec<_>>(),
            "pos": pos_of(n),
        }),
        ast::Expr::Literal(n) => literal_to_json(n),
        ast::Expr::Paren(n) => json!({
            "kind": "Paren",
            "expr": n.expr().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "pos": pos_of(n),
        }),
        ast::Expr::Path(n) => json!({
            "kind": "Path",
            "parts": path_parts_to_json(n),
            "pos": pos_of(n),
        }),
        ast::Expr::Root(_) => Value::Null,
        ast::Expr::Select(n) => json!({
            "kind": "Select",
            "expr": n.expr().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "attrpath": n.attrpath().map(attrpath_to_json).unwrap_or(json!([])),
            "default": n.default_expr().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "pos": pos_of(n),
        }),
        ast::Expr::Str(n) => json!({
            "kind": "Str",
            "parts": str_parts_to_json(n),
            "indented": is_indented_str(n),
            "pos": pos_of(n),
        }),
        ast::Expr::UnaryOp(n) => json!({
            "kind": "UnaryOp",
            "op": unop_kind(n),
            "expr": n.expr().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "pos": pos_of(n),
        }),
        ast::Expr::With(n) => json!({
            "kind": "With",
            "ns": n.namespace().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "body": n.body().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "pos": pos_of(n),
        }),
    }
}

fn entries_to_json(entries: AstChildren<ast::Entry>) -> Vec<Value> {
    entries.map(|e| match e {
        ast::Entry::AttrpathValue(av) => json!({
            "kind": "AttrpathValue",
            "path": av.attrpath().map(attrpath_to_json).unwrap_or(json!([])),
            "value": av.value().as_ref().map(expr_to_json).unwrap_or(Value::Null),
        }),
        ast::Entry::Inherit(i) => json!({
            "kind": "Inherit",
            "from": i.from().and_then(|f| f.expr()).as_ref().map(expr_to_json).unwrap_or(Value::Null),
            "names": i.attrs().map(attr_to_string).collect::<Vec<_>>(),
        }),
    }).collect()
}

fn attrpath_to_json(p: ast::Attrpath) -> Value {
    Value::Array(p.attrs().map(|a| Value::String(attr_to_string(a))).collect())
}

fn attr_to_string(a: ast::Attr) -> String {
    match a {
        ast::Attr::Ident(i) => i.ident_token().map(|t| t.text().to_string()).unwrap_or_default(),
        ast::Attr::Dynamic(d) => format!("${{{}}}",
            d.expr().as_ref().map(|e| expr_text(e)).unwrap_or_default()),
        ast::Attr::Str(s) => format!("\"{}\"", str_text(&s)),
    }
}

fn expr_text(e: &ast::Expr) -> String {
    e.syntax().text().to_string()
}

fn str_text(s: &ast::Str) -> String {
    // Strip the surrounding quotes.
    let raw = s.syntax().text().to_string();
    raw.trim_start_matches('"').trim_end_matches('"').to_string()
}

fn is_indented_str(s: &ast::Str) -> bool {
    s.syntax().text().to_string().starts_with("''")
}

fn str_parts_to_json(s: &ast::Str) -> Vec<Value> {
    s.parts().map(|p| match p {
        ast::InterpolPart::Literal(lit) => json!({
            "kind": "Literal",
            "text": lit.syntax().text().to_string(),
        }),
        ast::InterpolPart::Interpolation(i) => json!({
            "kind": "Interp",
            "expr": i.expr().as_ref().map(expr_to_json).unwrap_or(Value::Null),
        }),
    }).collect()
}

fn path_parts_to_json(p: &ast::Path) -> Vec<Value> {
    p.parts().map(|part| match part {
        ast::InterpolPart::Literal(lit) => json!({
            "kind": "Literal",
            "text": lit.syntax().text().to_string(),
        }),
        ast::InterpolPart::Interpolation(i) => json!({
            "kind": "Interp",
            "expr": i.expr().as_ref().map(expr_to_json).unwrap_or(Value::Null),
        }),
    }).collect()
}

fn literal_to_json(n: &ast::Literal) -> Value {
    match n.kind() {
        ast::LiteralKind::Float(f) => json!({
            "kind": "Float",
            "value": f.value().unwrap_or(0.0),
            "pos": pos_of(n),
        }),
        ast::LiteralKind::Integer(i) => json!({
            "kind": "Integer",
            "value": i.value().unwrap_or(0),
            "pos": pos_of(n),
        }),
        ast::LiteralKind::Uri(_) => json!({
            "kind": "Uri",
            "text": n.syntax().text().to_string(),
            "pos": pos_of(n),
        }),
    }
}

fn binop_kind(n: &ast::BinOp) -> &'static str {
    use ast::BinOpKind::*;
    match n.operator().unwrap_or(Concat) {
        Concat        => "++",
        Update        => "//",
        Add           => "+",
        Sub           => "-",
        Mul           => "*",
        Div           => "/",
        And           => "&&",
        Equal         => "==",
        Implication   => "->",
        Less          => "<",
        LessOrEq      => "<=",
        More          => ">",
        MoreOrEq      => ">=",
        NotEqual      => "!=",
        Or            => "||",
    }
}

fn unop_kind(n: &ast::UnaryOp) -> &'static str {
    use ast::UnaryOpKind::*;
    match n.operator().unwrap_or(Negate) {
        Invert => "!",
        Negate => "-",
    }
}

fn param_to_json(p: ast::Param) -> Value {
    match p {
        ast::Param::IdentParam(i) => json!({
            "kind": "Ident",
            "name": i.ident().and_then(|x| x.ident_token()).map(|t| t.text().to_string()).unwrap_or_default(),
        }),
        ast::Param::Pattern(p) => {
            let entries: Vec<Value> = p.pat_entries().map(|e| json!({
                "name": e.ident().and_then(|x| x.ident_token()).map(|t| t.text().to_string()).unwrap_or_default(),
                "default": e.default().as_ref().map(expr_to_json).unwrap_or(Value::Null),
            })).collect();
            json!({
                "kind": "Pattern",
                "entries": entries,
                "ellipsis": p.ellipsis_token().is_some(),
                "bind": p.pat_bind().and_then(|b| b.ident()).and_then(|i| i.ident_token()).map(|t| t.text().to_string()),
            })
        }
    }
}
