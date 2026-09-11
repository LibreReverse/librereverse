import Foundation
import NaturalLanguage
import Darwin
@main struct Evaluation {
 static func main() async throws {
 let docs = [
 "The release was postponed until October because the security audit found a vulnerability.",
 "The customer ended the subscription after repeated outages and poor support.",
 "We hired three engineers to reduce the backlog before the winter launch.",
 "The invoice is overdue. Finance will ask the buyer to settle the balance.",
 "Sofia owns the migration to the new database. Her deadline is November 14.",
 "Sonia owns the migration to the new database. Her deadline is November 21.",
 "The final approved budget for Project Cedar is 48172 dollars.",
 "The final approved budget for Project Cedar is 48127 dollars.",
 "At the first planning meeting, Atlas was blocked by a missing vendor contract.",
 "At the follow-up meeting, the Atlas vendor signed and procurement cleared the blocker.",
 "The team decided to encrypt stored recordings and remove credentials from logs.",
 "The café offers oat milk and freshly baked bread every morning.",
 "A new retention campaign gives subscribers a discount when they renew.",
 "We shipped the release in September after completing the performance audit.",
 "The buyer already paid the invoice. Finance closed the account.",
 "The production outage was caused by an expired certificate, not the database migration.",
 "The doctor recommended rest and plenty of water after the race.",
 "The budget discussion was postponed until next week; no amount was approved."
 ]
 let questions: [(String,String,Set<Int>)] = [
 ("paraphrase","Why did we delay shipping the product?",[0]),
 ("paraphrase","Which client stopped paying for the service because it was unreliable?",[1]),
 ("paraphrase","How are we adding people to finish outstanding development work?",[2]),
 ("paraphrase","Who needs a reminder to pay what they owe?",[3]),
 ("paraphrase","What protects private data from exposure?",[10]),
 ("exact-name","What is Sofia's migration deadline?",[4]),
 ("exact-name","What is Sonia's migration deadline?",[5]),
 ("exact-number","Which approved budget was 48172 dollars?",[6]),
 ("exact-number","Which approved budget was 48127 dollars?",[7]),
 ("cross-meeting","How did the Atlas vendor contract blocker change between meetings?",[8,9]),
 ("negation","What caused the production outage rather than the migration?",[15]),
 ("exact-topic","Which invoice has already been paid?",[14])
 ]
 let stop:Set<String> = ["a","an","the","what","which","why","who","how","we","did","is","was","are","to","it","for","of","they","from","has","been","in","and","s","because","with"]
 func tokens(_ s:String)->Set<String> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(stop) }
 let docTokens=docs.map(tokens)
 var totals=["lexical":0.0,"semantic":0.0,"fusion":0.0]
 var groups:[String:[String:Double]]=[:]
 let reranker=LibreReverseSemanticReranker()
 let begin=Date()
 for (category,q,relevant) in questions {
   let qt=tokens(q)
   // Exact-token OR matching, newest-first, models the current recency baseline
   // on this small fixture; no SQLite stemming/tokenizer equivalence is claimed.
   let lexical=docs.indices.filter { !qt.intersection(docTokens[$0]).isEmpty }.sorted(by: >)
   let candidates=docs.indices.map { i in LibreReverseSemanticReranker.Candidate(id:String(i),text:docs[i],lexicalRank:lexical.firstIndex(of:i).map{$0+1}) }
   let started=Date()
   guard let ranked=try await reranker.rank(question:q,candidates:candidates,limit:docs.count) else { print("unavailable"); return }
   let semantic=ranked.sorted{$0.semanticScore > $1.semanticScore}.compactMap{Int($0.id)}
   let fusion=ranked.compactMap{Int($0.id)}
   let runs=["lexical":lexical,"semantic":semantic,"fusion":fusion]
   var row:[String:Any] = ["category":category,"question":q,"relevant":relevant.sorted(),"seconds":Date().timeIntervalSince(started)]
   for (name,ranks) in runs {
      let recall=Double(Set(ranks.prefix(3)).intersection(relevant).count)/Double(relevant.count)
      totals[name,default:0] += recall
      groups[category,default:[:]][name,default:0] += recall
      row[name]=["top3":Array(ranks.prefix(3)),"recallAt3":recall] as [String:Any]
   }
   print(String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
 }
 var usage=rusage(); getrusage(RUSAGE_SELF,&usage)
 print("SUMMARY \(totals.mapValues{$0/Double(questions.count)}) seconds=\(Date().timeIntervalSince(begin)) peakRSSBytes=\(usage.ru_maxrss) groups=\(groups)")
 // Sustained bounded 100-candidate case, with four text chunks per source.
 let big=String(repeating:docs[0]+" ",count:70)
 let candidates=(0..<100).map{LibreReverseSemanticReranker.Candidate(id:String($0),text:big,lexicalRank:$0+1)}
 let started=Date()
 _=try await reranker.rank(question:"Why was the release delayed?",candidates:candidates,limit:10)
 getrusage(RUSAGE_SELF,&usage)
 print("BOUNDS 100x4000chars seconds=\(Date().timeIntervalSince(started)) peakRSSBytes=\(usage.ru_maxrss)")
 }
}
