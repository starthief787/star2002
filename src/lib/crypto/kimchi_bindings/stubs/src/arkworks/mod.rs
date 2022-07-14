//! This module contains wrapper types to Arkworks types.
//! To use Arkwork types in OCaml, you have to convert to these types,
//! and convert back from them to use them in Rust.
//!
//! For example:
//!
//! ```
//! use marlin_plonk_bindings::arkworks::BigInteger256;
//! use ark_ff::BigInteger256;
//!
//! #[ocaml::func]
//! pub fn caml_add(x: BigInteger256, y: BigInteger256) -> BigInteger256 {
//!    let x: BigInteger256 = x.into();
//!    let y: BigInteger256 = y.into();
//!    (x + y).into()
//! }
//! ```
//!

pub mod bigint_256;
pub mod fields;
pub mod group_affine;
pub mod group_projective;

// re-export what's important

pub use bigint_256::BigInteger256;
pub use fields::{fp::CamlFp, fq::CamlFq};
pub use group_affine::{CamlGPallas, CamlGVesta, CamlGroupAffine};
pub use group_projective::{CamlGroupProjectivePallas, CamlGroupProjectiveVesta};
