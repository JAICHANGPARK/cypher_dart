grammar Cypher;

cypher
  : statement (';' statement)* EOF
  ;

statement
  : clause+
  ;

clause
  : optionalMatchClause
  | matchClause
  | whereClause
  | withClause
  | returnClause
  | orderByClause
  | skipClause
  | limitClause
  | createClause
  | mergeClause
  | setClause
  | removeClause
  | deleteClause
  ;

optionalMatchClause
  : OPTIONAL MATCH expression
  ;

matchClause
  : MATCH expression
  ;

whereClause
  : WHERE expression
  ;

withClause
  : WITH expression
  ;

returnClause
  : RETURN expression
  ;

orderByClause
  : ORDER BY expression
  ;

skipClause
  : SKIP expression
  ;

limitClause
  : LIMIT expression
  ;

createClause
  : CREATE expression
  ;

mergeClause
  : MERGE expression
  ;

setClause
  : SET expression
  ;

removeClause
  : REMOVE expression
  ;

deleteClause
  : DELETE expression
  ;

expression
  : token+
  ;

token
  : IDENTIFIER
  | NUMBER
  | STRING
  | PUNCT
  ;

OPTIONAL: 'OPTIONAL';
MATCH: 'MATCH';
WHERE: 'WHERE';
WITH: 'WITH';
RETURN: 'RETURN';
ORDER: 'ORDER';
BY: 'BY';
SKIP: 'SKIP';
LIMIT: 'LIMIT';
CREATE: 'CREATE';
MERGE: 'MERGE';
SET: 'SET';
REMOVE: 'REMOVE';
DELETE: 'DELETE';

IDENTIFIER: [a-zA-Z_][a-zA-Z_0-9]*;
NUMBER: [0-9]+;
STRING: '\'' (~['\\\\] | '\\\\' .)* '\'' | '"' (~["\\\\] | '\\\\' .)* '"';
PUNCT: [(){}\\[\\],.:=+*/<>!?|-];
WS: [ \\t\\r\\n]+ -> skip;
