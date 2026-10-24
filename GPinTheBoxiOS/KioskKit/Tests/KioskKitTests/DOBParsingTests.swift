import Testing
@testable import KioskKit

@Test(arguments: [
    ("1980-05-01", "1980-05-01"), (" 1/5/1980 ", "1980-05-01"), ("01/05/1980", "1980-05-01"), ("1-5-1980", "1980-05-01"),
    ("1.5.1980", "1980-05-01"), ("1 5 1980", "1980-05-01"), ("1 May 1980", "1980-05-01"), ("1 may 1980", "1980-05-01"),
    ("1 MAY 1980", "1980-05-01"), ("12 Sep 1975", "1975-09-12"), ("3 Sept 1975", "1975-09-03"), ("May 1 1980", "1980-05-01"),
    ("May 1, 1980", "1980-05-01"), ("1st May 1980", "1980-05-01"), ("22nd February 2000", "2000-02-22"),
    ("23rd Mar 1990", "1990-03-23"), ("December 31st, 1999", "1999-12-31"), ("29/2/2000", "2000-02-29"),
    ("2999-01-01", "2999-01-01"),
])
func isoDOBParses(raw: String, iso: String) {
    #expect(AnswerFormatting.isoDOB(from: raw) == iso)
}
@Test(arguments: ["1/5/80", "31/02/1980", "13/13/1980", "Jane Demo", "", "1980-02-30", "29/2/1900", "May 1980",
                  "sometime in May", "1/5-1980", "32 May 1980", "1 Mayo 1980", "1980-5-1", "0/5/1980"])
func isoDOBRejects(raw: String) {
    #expect(AnswerFormatting.isoDOB(from: raw) == nil)
}
