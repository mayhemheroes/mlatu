#![feature(with_options)]

use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

use clap::{App, Arg, SubCommand};
use mlatu::prolog::codegen;
use mlatu::prolog::util::{AssertLocation, ContextExt};
use mlatu::{binary, parse_rules, prolog, Editor, Interactive, Rule};
use tokio::sync::mpsc::unbounded_channel;

fn load_text_file(filename:&str) -> Result<Vec<Rule>, String> {
  match std::fs::read(filename) {
    | Ok(bytes) => match String::from_utf8(bytes) {
      | Ok(string) => match parse_rules(&string) {
        | Ok(rules) => Ok(rules),
        | Err(e) => Err(format!("Error while parsing '{}': {}", filename, e)),
      },
      | Err(e) => Err(format!("Error in decoding '{}': {}", filename, e)),
    },
    | Err(e) => Err(format!("Error while reading '{}': {}", filename, e)),
  }
}

fn load_binary_file(filename:&str) -> Result<Vec<Rule>, String> {
  match File::with_options().append(true).create(true).read(true).open(filename) {
    | Ok(mut file) => {
      let mut buf = Vec::new();
      match file.read_to_end(&mut buf) {
        | Ok(_) => match binary::deserialize_rules(&mut buf) {
          | Some(rules) => Ok(rules),
          | None => Err(format!("Error while deserializing {}", filename)),
        },
        | Err(e) => Err(format!("Error while reading '{}': {}", filename, e)),
      }
    },
    | Err(e) => Err(format!("Error while opening '{}': {}", filename, e)),
  }
}

fn load_file(filename:&str) -> Result<Vec<Rule>, String> {
  let path = Path::new(&filename);
  match path.extension().unwrap().to_str().unwrap() {
    | "mlt" => load_text_file(filename),
    | "mlb" => load_binary_file(filename),
    | ext => Err(format!("Unrecognized file extension: {}", ext)),
  }
}

#[tokio::main]
async fn main() -> Result<(), String> {
  let matches = App::new("mlatu")
                 .version("0.1")
                 .author("Caden Haustein <code@brightlysalty.33mail.com>")
                 .about("the mlatu language interface")
                 .arg(Arg::with_name("FILES").multiple(true).help("Sets the rule files to use")).
                  arg(Arg::with_name("no-prelude").long("no-prelude").help("Doesn't load the normal prelude"))
                  .subcommand(SubCommand::with_name("edit")
                    .about("the mlatu structured editor")
                    .version("0.1")
                    .author("Caden Haustein <code@brightlysalty.33mail.com>")
                    .arg(Arg::with_name("FILE").required(true).help("Sets the rule file to edit")
                  ))
                .get_matches();

  match matches.subcommand() {
    | ("edit", Some(sub_matches)) => {
      let filename = sub_matches.value_of("FILE").unwrap();
      let rules = load_file(filename)?;
      let mut path = PathBuf::from(filename);
      let _ = path.set_extension("mlb");
      match path.canonicalize() {
        | Ok(path) => Editor::new(path, &rules)?.run().await,
        | Err(_) => eprintln!("Path could not be canonicalized"),
      }
    },
    | _ => {
      let mut files = Vec::new();
      if !matches.is_present("no-prelude") {
        files.push("prelude.mlb".to_string());
      }
      if let Some(args) = matches.values_of("FILES") {
        files.extend(args.map(ToOwned::to_owned));
      }
      match files.into_iter().map(|file| load_file(&file)).collect::<Result<Vec<_>, _>>() {
        | Ok(rules) => {
          let (prolog_tx, mut interactive_rx) = unbounded_channel();
          let (interactive_tx, prolog_rx) = unbounded_channel();

          std::thread::spawn(move || {
            prolog::thread(|ctx, module| {
                             let rules = rules.into_iter().flatten().collect::<Vec<_>>();
                             let clauses = codegen::generate(ctx, &rules).unwrap();
                             clauses.into_iter()
                                    .try_for_each(|clause| {
                                      ctx.assert(&clause.clause, Some(module), AssertLocation::Last)
                                    })
                                    .unwrap();
                           },
                           &prolog_tx,
                           prolog_rx)
          });

          Interactive::new(interactive_tx).map_err(|e| e.to_string())?
                                          .run(&mut interactive_rx)
                                          .await;
        },
        | Err(error) => eprintln!("{}", error),
      }
    },
  }

  Ok(())
}