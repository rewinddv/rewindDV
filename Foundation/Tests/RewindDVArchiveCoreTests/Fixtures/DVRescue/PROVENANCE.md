# DVRescue schema and synthetic importer fixture

`dvrescue.xsd` is an unmodified BSD-3-Clause copy of tools/dvrescue.xsd,
version 1.2.1, from mipops/dvrescue 5cead7a5dae4ec7ffdf24115c8e3bc6d9c05c033.
Full copyright, conditions and disclaimer are retained in ThirdPartyNotices.txt.
`synthetic-many-attributes.xml` is newly authored Apache-2.0 structural test data,
with invented metadata. It is not a DVRescue-generated capture report. The
identifying original report is absent. The importer test runs without skips,
checks aggregate-versus-DIF counts and unbound identity, and validates the XSD.
