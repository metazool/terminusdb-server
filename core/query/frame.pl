:- module(frame, [
              %% Give a class frame for a given class.
              class_frame/3,
              % Various class/document queries
              all_documents/2,
              all_classes/2,
              class_properties/3,
              class_property_frame/4,
              %% Fill a given class frame with data.
              fill_class_frame/4,
              document_filled_frame/3,
              all_document_instances/2,
              all_document_iris/2,
              % Get an object as described by a frame.
              % (should this be exported?)
              % document_object/4,
              % As JSON-LD
              document_jsonld/3,
              % As JSON-LD with a depth
              document_jsonld/4,
              class_frame_jsonld/3,
              filled_frame_jsonld/3,
              object_edges/3,
              delete_object/2,
              update_object/2,
              update_object/3,
              document_filled_class_frame_jsonld/4,
              object_instance_graph/3
          ]).

/** <module> Frames
 *
 * Frame code for generating either objects based on ontology information
 * or descriptors of the object type - or the combination of the two
 * coupled together.
 *
 * * * * * * * * * * * * * COPYRIGHT NOTICE  * * * * * * * * * * * * * * *
 *                                                                       *
 *  This file is part of TerminusDB.                                     *
 *                                                                       *
 *  TerminusDB is free software: you can redistribute it and/or modify   *
 *  it under the terms of the GNU General Public License as published by *
 *  the Free Software Foundation, under version 3 of the License.        *
 *                                                                       *
 *                                                                       *
 *  TerminusDB is distributed in the hope that it will be useful,        *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of       *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the        *
 *  GNU General Public License for more details.                         *
 *                                                                       *
 *  You should have received a copy of the GNU General Public License    *
 *  along with TerminusDB.  If not, see <https://www.gnu.org/licenses/>. *
 *                                                                       *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

:- use_module(inference).
:- use_module(expansions).
:- use_module(ask).
:- use_module(frame_types).
:- use_module(jsonld).
:- use_module(global_prefixes).

:- use_module(core(util)).
:- use_module(core(triple)).
:- use_module(core(validation)).
:- use_module(core(transaction)).


:- use_module(library(apply)).
:- use_module(library(yall)).
:- use_module(library(apply_macros)).

class_record(Database,Class,[class=Class|L]) :-
    maybe_meta(Class,Database,L).

property_record(Database,Property,L) :-
    maybe_meta(Property,Database,L).

all_documents(Database,AER) :-
    unique_solutions(E,document(E,Database),AE),
    maplist(class_record(Database),AE,AER).

all_classes(Database,ACR) :-
    unique_solutions(C,class(C,Database),AC),
    maplist(class_record(Database),AC,ACR).

/**
 * get_label(Document,Database,Label) is semidet.
 */
get_label(Document,Database,Label) :-
    database_instance(Database,Instance),
    global_prefix_expand(rdfs:label,LabelProp),
    xrdf(Instance,Document,LabelProp,Label@_),
    !.
get_label(Document,Database,Label) :-
    database_instance(Database,Instance),
    global_prefix_expand(rdfs:label,LabelProp),
    xrdf(Instance,Document,LabelProp,Label@_),
    !.

get_some_label(E,Database,L) :-
    (   get_label(E,Database,L)
    ->  true
    ;   L=E).

/**
 * all_document_instances(Database,Ae) is semidet.
 *
 * Returns a list of URI=[type=Class,label=Label] elements, where
 * Class is an document class and Label is a string.
 */
all_document_instances(Database,AE) :-
    database_instance(Database,Instance),
    unique_solutions(E=[type=C,label=L],
                     (   xrdf(Instance,
                              E,rdf:type,C),
                         document(C,Database),
                         get_some_label(E,Database,L)),
                     AE).

all_document_iris(Database, IRIs) :-
    database_instance(Database, Instance),
    findall(IRI,
            (   xrdf(Instance,
                     IRI,rdf:type,C),
                document(C, Database)
            ),
            IRIs).

add_most_specific_property(Database,P,PList,Rp) :-
    % write('P: '),writeq(P),nl,
    member(Q,PList), % write('Q: '),writeq(Q),nl,
    (   subsumption_properties_of(P,Q,Database)
    *-> select(Q,PList,PListp), Rp=[P|PListp] % ,write('P < Q'),nl
    ;   subsumption_properties_of(Q,P,Database)
    *-> Rp=PList % ,write('Q < P'), nl
    ;   Rp=[P|PList]),
    % Hail mary - makes me so uncomfortable.
    !.
add_most_specific_property(_Database,P,PList,[P|PList]).

most_specific_properties(Database,Properties,SpecificProperties) :-
    foldl(add_most_specific_property(Database),Properties,[],SpecificProperties).

class_properties(Class, Database, PropertiesPrime) :-
    (   document(Class,Database)
    ->  DocumentProperties=['http://www.w3.org/2000/01/rdf-schema#label',
                            'http://www.w3.org/2000/01/rdf-schema#comment']
    ;   DocumentProperties=[]),
    (   setof(Super,subsumption_of(Class,Super,Database),Classes),
        setof(P,
              S^(member(S,Classes),
                 validate_schema:domain(P,S,Database)),
              Properties)
    ->  most_specific_properties(Database,Properties,MSProperties),
        append(MSProperties,DocumentProperties,PropertiesWithAbstract),
        database_schema(Database,Schema),
        exclude({Schema,Database}/[X]>>(
                    xrdf(
                         Schema,
                         X,system:tag,system:abstract)),
                PropertiesWithAbstract,
                PropertiesPrime)
    ;   PropertiesPrime=DocumentProperties).

%:- rdf_meta has_formula(r,o).
has_formula(Class,Database) :-
    (   sub_class_of(Class,_,Database)
    ;   intersection_of(Class,_,Database)
    ;   union_of(Class,_,Database)
    ;   disjoint_union_of(Class,_,Database)
    ;   one_of_list(Class,_,Database)
    ).

% restriction_type(+Class:uri, -Restriction:restriction_formula, +Database:database is nondet.
%
% Get the restriction formula for a restriction class.
%
%:- rdf_meta restriction_type(r,t,?).
restriction_type(CR,restriction([uri=CR,property=OP,someValuesFrom=C]),Database) :-
    database_schema(Database,Schema),
    xrdf(Schema,CR,owl:someValuesFrom,C),
    !,
    xrdf(Schema,CR,owl:onProperty,OP).
restriction_type(CR,restriction([uri=CR,property=OP,allValuesFrom=C]),Database) :-
    database_schema(Database,Schema),
    xrdf(Schema,CR,owl:allValuesFrom,C),
    !,
    xrdf(Schema,CR,owl:onProperty,OP).
restriction_type(CR,restriction([uri=CR,property=OP,minCardinality=N]),Database) :-
    database_schema(Database,Schema),
    xrdf(Schema,CR,owl:minCardinality,CardStr^^_),
    !,
    xrdf(Schema,CR,owl:onProperty,OP),
    (number(CardStr)-> CardStr=N ; atom_number(CardStr,N)).
restriction_type(CR,restriction([uri=CR,property=OP,maxCardinality=N]),Database) :-
    database_schema(Database,Schema),
    xrdf(Schema,CR,owl:maxCardinality,CardStr^^_),
    !,
    xrdf(Schema,CR,owl:onProperty,OP),
    (number(CardStr)-> CardStr=N ; atom_number(CardStr,N)).
restriction_type(CR,restriction([uri=CR,property=OP,cardinality=N]),Database) :-
    database_schema(Database,Schema),
    xrdf(Schema,CR,owl:cardinality,CardStr^^_),
    !,
    xrdf(Schema,CR,owl:onProperty,OP),
    (number(CardStr)-> CardStr=N ; atom_number(CardStr,N)).
restriction_type(CR,restriction([uri=CR,property=OP,minQualifiedCardinality=N,onClass=C]), Database) :-
    database_schema(Database,Schema),
    xrdf(Schema,CR,owl:minQualifiedCardinality,CardStr^^_),
    !,
    xrdf(Schema,CR,owl:onProperty,OP),
    xrdf(Schema,CR,owl:onClass,C),
    (number(CardStr)-> CardStr=N ; atom_number(CardStr,N)).
restriction_type(CR,restriction([uri=CR,property=OP,maxQualifiedCardinality=N,onClass=C]), Database) :-
    database_schema(Database,Schema),
    xrdf(Schema,CR,owl:maxQualifiedCardinality,CardStr^^_),
    !,
    xrdf(Schema,CR,owl:onProperty,OP),
    xrdf(Schema,CR,owl:onClass,C),
    (number(CardStr)-> CardStr=N ; atom_number(CardStr,N)).
restriction_type(CR,restriction([uri=CR,property=OP,qualifiedCardinality=N,onClass=C]), Database) :-
    database_schema(Database,Schema),
    xrdf(Schema,CR,owl:qualifiedCardinality,CardStr^^_),
    !,
    xrdf(Schema,CR,owl:onProperty,OP),
    xrdf(Schema,CR,owl:onClass,C),
    (number(CardStr)-> CardStr=N ; atom_number(CardStr,N)).
restriction_type(CR,restriction([uri=CR,property=OP,hasValue=V]), Database) :-
    database_schema(Database,Schema),
    xrdf(Schema,CR,owl:onProperty,OP),
    xrdf(Schema,CR,owl:hasValue,V).

% ignore modeline
% is_class_formula(+Formula:any) is semidet.
%
% True if Formula is a class formula
is_class_formula(Class<Superclasses) :-
    is_uri(Class),
    exclude(is_class_formula,Superclasses,[]).
is_class_formula(Class=and(Sols)) :-
    is_uri(Class),
    exclude(is_class_formula,Sols,[]).
is_class_formula(Class=or(Sols)) :-
    is_uri(Class),
    exclude(is_class_formula,Sols,[]).
is_class_formula(Class=xor(Sols)) :-
    is_uri(Class),
    exclude(is_class_formula,Sols,[]).
is_class_formula(Class=oneOf(OneList)) :-
    is_uri(Class),
    exclude(is_uri,OneList,[]).
is_class_formula(restriction(Restriction)) :-
    is_property_restriction(Restriction).
is_class_formula(class(Class)) :-
    is_uri(Class).

:- multifile error:has_type/2.
error:has_type(class_formula,X) :-
    is_class_formula(X).

/*
 * class_assertion(+Database:database +Class:uri, -Formula:class_formula) is nondet.
 *
 * Get one solution of the OWL class assertions
 *
 * @param Database A graph object identifying the current schema graph.
 * @param Class Atom URI identifier of rfds or owl Class.
 * @param Formula Term describing the class relationships.
 *
 * TODO: Formula should be a type
 */
%:- rdf_meta class_assertion(o,r,t).
class_assertion(Database, Class, (Class<Solns)) :-
    %class(Class),
    setof(Sol, Y^(sub_class_of(Class,Y,Database),
                  class_formula(Y, Database, Sol)),
          Solns).
class_assertion(Database, Class, (Class=and(Solns))) :-
    %class(Class,Database),
    setof(Sol,Y^(intersection_of(Class,Y,Database),
                 class_formula(Y,Database,Sol)),
          Solns).
class_assertion(Database,Class,(Class=or(Solns))) :-
    %class(Class,Database),
    setof(Sol,Y^(union_of(Class,Y,Database),
                 class_formula(Y,Database,Sol)),
          Solns).
class_assertion(Database,Class,(Class=xor(Solns))) :-
    %class(Class,Database),
    setof(Sol,Y^(disjoint_union_of(Class,Y,Database),
                 class_formula(Y,Database,Sol)),
          Solns).
class_assertion(Database,Class,(Class=oneOf(OneList))) :-
    one_of_list(Class,OneList,Database).
class_assertion(Database,Class,RType) :-
    restriction(Class,Database),
    restriction_type(Class,RType,Database).
class_assertion(Database,Class,class(Class)) :-
    immediate_class(Class,Database),
    \+ restriction(Class,Database),
    \+ has_formula(Class,Database).

/*
 * class_formula(+Class:uri, +Database:database -Formula:class_formula) is semidet.
 *
 * Create a formula describing the manner in which the class is
 * defined.
 *
 * @param Database A graph idntifying the current schema graph.
 * @param Class Atom URI identifier of rfds or owl Class.
 * @param Formula Term describing the class relationships.
 */
:- table class_formula/3.
class_formula(Class,Database,F) :-
    setof(Sol,class_assertion(Database,Class,Sol), Solns),
    (   [F]=Solns
    ->  true
    ;   F=(Class=and(Solns))
    ).

maybe_label(C,Database,[label=L]) :-
    label(C,L,Database),
    !.
maybe_label(_,_,[]).

maybe_comment(C,Database,[comment=Comment]) :-
    comment(C,Comment,Database),
    !.
maybe_comment(_,_,[]).

maybe_system_tag(C,Database,[system_tag=DC]) :-
    system_tag(C,DC,Database),
    !.
maybe_system_tag(_,_,[]).

:- table maybe_meta/3.
maybe_meta(C,Database,LCD) :-
    maybe_label(C,Database,Label),
    maybe_comment(C,Database,Comment),
    maybe_system_tag(C,Database,DCOGTag),
    append(Label, Comment, LC),
    append(LC,DCOGTag,LCD).

decorate_elements([],_Database,[]).
decorate_elements([Elt|Rest],Database,[MLC|Restp]) :-
    class_record(Database,Elt,MLC),
    decorate_elements(Rest,Database,Restp).

/**
 * property_restriction(+Property:uri,+Database:databasePR:property_restriction) is det.
 *
 * Obtains a property restriction which is intrinsic to the property rather than
 * a result of a restriction class.
 */
property_restriction(P,Database,R) :-
    (   functional_property(P,Database)
    ->  R=[uri=P,property=P,cardinality=1]
    ;   R=true
    ).


/**
 * classes_below(+Class:uri, +Database, -Below:list(uri)) is det.
 *
 * Get all classes below us in the subsumption hierarchy,
 * excluding owl:Nothing or abstract classes.
 */
classes_below(Class,Database,BelowList) :-
    unique_solutions(Below,subsumption_of(Below,Class,Database),Classes),
    exclude([X]>>(X='http://www.w3.org/2002/07/owl#Nothing'), Classes, ClassesNoBottom),
    database_schema(Database,Schema),
    exclude({Database, Schema}/[X]>>(
                xrdf(Schema,
                     X,system:tag,system:abstract)),
            ClassesNoBottom,
            BelowList).

simplify_restriction_list(T,R,S) :-
    (   R = [S]
    ->  true
    ;   R = []
    ->  S=true
    ;   S=[type=T,
           operands=R]).

/**
 * normalise_restriction(+Restriction:property_restriction,-N:property_restriction) is det.
 *
 * Disjunctive normal form for restriction.
 */
normalise_restriction([type=sub, operands=Results],N) :-
    !,
    maplist([X,Y]>>normalise_restriction(X,Y),Results,Normalised),
    exclude([X]>>(X=true),Normalised,Result),
    debug(terminus(frame(normalise)),'normalise_restriction sub: ~p',[Result]),
    (   exclude([F]>>(F=[type=T|_], member(T,[and,sub])), Result, [])
    ->  foldl([F,R,O]>>(F=[type=_,operands=Fs], append(Fs,R,O)),Result,[],Acc)
    ;   Acc=Result),
    simplify_restriction_list(sub,Acc,N).
normalise_restriction([type=and, operands=Results],N) :-
    !,
    maplist([X,Y]>>normalise_restriction(X,Y),Results,Normalised),
    exclude([X]>>(X=true),Normalised,Result),
    debug(terminus(frame(normalise)),'normalise_restriction and: ~p',[Result]),
    (   exclude([F]>>(F=[type=T|_], member(T,[and,sub])), Result, [])
    ->  foldl([F,R,O]>>(F=[type=_,operands=Fs], append(Fs,R,O)),Result,[],Acc)
    ;   Acc=Result),
    simplify_restriction_list(and,Acc,N).
normalise_restriction([type=or, operands=Results],N) :-
    !,
    maplist([X,Y]>>(normalise_restriction(X,Y)),Results,Normalised),
    simplify_restriction_list(or,Normalised,N).
normalise_restriction([type=xor, operands=Results],N) :-
    !,
    maplist([X,Y]>>normalise_restriction(X,Y),Results,Normalised),
    exclude([X]>>(X=true),Normalised,Result),
    simplify_restriction_list(xor,Result,N).
normalise_restriction([uri=U|Res],[uri=U|Res]) :-
    !.
normalise_restriction(true,true).

/*
 * restriction_formula(+Formula:class_formula,+Database:database
 *                     -RestrictionFormula:property_restriction) is det.
 *
 * Calculate the formula of restrictions for a class.
 */
restriction_formula(_<L,Database,Norm) :-
    !,
    maplist({Database}/[C,F]>>(restriction_formula(C,Database,F)),
            L,R),
    simplify_restriction_list(sub,R,S),
    normalise_restriction(S,Norm).
restriction_formula(_=or(L),Database,S) :-
    !,
    maplist({Database}/[C,F]>>(restriction_formula(C,Database,F)),
            L,R),
    simplify_restriction_list(or,R,S).
restriction_formula(_=and(L),Database,S) :-
    !,
    maplist({Database}/[C,F]>>(restriction_formula(C,Database,F)),
            L,R),
    simplify_restriction_list(and,R,S).
restriction_formula(_=xor(L),Database,S) :-
    !,
    maplist({Database}/[C,F]>>(restriction_formula(C,Database,F)),
            L,R),
    simplify_restriction_list(xor,R,S).
restriction_formula(class(_),_,true) :-
    !.
restriction_formula(restriction(L),_,L) :-
    !.
restriction_formula(_=oneOf(_),_,true).

/**
 * select_restriction(+R:property_restriction,+P:uri,+Database:database-S:property_restriction) is det.
 */
select_restriction(P,R,G,Restriction) :-
    select_restriction_(R,P,G,Restriction).

select_restriction_([type=Type,operands=Operands],P,G,Restriction) :-
    !,
    convlist({P,G}/[R,S]>>select_restriction(P,R,G,S), Operands, NewOperands),
    simplify_restriction_list(Type,NewOperands,Restriction).
select_restriction_([uri=U,property=Q|R],P,G,Restriction) :-
    !,
    (   subsumption_properties_of(P,Q,G)
    ->  Restriction = [uri=U,property=P|R]
    ;   Restriction = true
    ).
select_restriction_(true,_,_,true).


/**
 * calculate_property_restriction(+Property:uri,+Restriction_Formula:property_restriction,
 *                                +Database:database-Restriction:property_restriction)  is det.
 *
 * Calculate the full restriction on a given property, from the formula and
 * constraints directly on the property.
 */
calculate_property_restriction(Property,Restriction_Formula,Database,Restriction) :-
    select_restriction(Property,Restriction_Formula,Database,CalculatedRestriction),
    property_restriction(Property,Database,PropRestriction),
    normalise_restriction([type=and,operands=[PropRestriction,CalculatedRestriction]],
                          Restriction).

apply_restiction_(annotation,Class,Property,_Database,
                  Restriction,Range,Record_Remainder,
                  [type=datatypeProperty,
                   property=Property,
                   domain=Class,
                   restriction=Restriction,
                   range=Range
                   |Record_Remainder]).
apply_restriction_(datatype,Class,Property,_Database,
                   Restriction,Range,Record_Remainder,
                   [type=datatypeProperty,
                    property=Property,
                    domain=Class,
                    restriction=Restriction,
                    range=Range
                    |Record_Remainder]).
apply_restriction_(document,Class,Property,Database,
                   Restriction,Range,Record_Remainder,
                   [type=objectProperty,
                    property=Property,
                    domain=Class,
                    range=Range,
                    restriction=Restriction,
                    frame=[type=document,class=Range|RTail]
                    |Record_Remainder]) :-
    once(maybe_label(Range,Database,RLabel)),
    once(maybe_comment(Range,Database,RComment)),
    append(RLabel, RComment, RTail).
apply_restriction_(one_of(OneList),Class,Property,Database,
                   Restriction,Range,Record_Remainder,
                   [type=objectProperty,
                    property=Property,
                    domain=Class,
                    range=Range,
                    restriction=Restriction,
                    frame=[type=oneOf, elements=DecoratedOneList]
                    |Record_Remainder]) :-
    once(decorate_elements(OneList,Database,DecoratedOneList)).
apply_restriction_(object,Class,Property,Database,
                   Restriction,Range,Record_Remainder,
                   [type=objectProperty,
                    property=Property,
                    domain=Class,
                    range=Range,
                    frame=Frame,
                    restriction=Restriction
                    |Record_Remainder]) :-
    once(classes_below(Range,Database,Below)),
    (   [NextClass] = Below
        % singleton choice of class class should just be rendered.
    ->  class_frame_aux(NextClass,Database,Frame)
        % We can't decide from here...
    ;   convlist({Database}/[C,F]>>(class_frame_aux(C,Database,F)),Below,Frames),
        Frame=[type=class_choice,operands=Frames]
    ).

/**
 * apply_restriction(+Class:uri,+Property:uri,+Database:database
 *                   +RestrictionFormula:property_restriction,Frame) is semidet.
 *
 *
 */
apply_restriction(Class,Property,Database,Restriction_Formula,Frame) :-
    most_specific_range(Property,Range,Database),
    (   annotation_property(Property,Database)
    ->  Type = annotation
    ;   datatype(Range,Database)
    ->  Type = datatype
    ;   document(Range,Database)
    ->  Type = document
    ;   one_of_list(Range,OneList,Database)
    ->  Type = one_of(OneList)
    ;   Type = object),
    once(calculate_property_restriction(Property,Restriction_Formula,Database,Restriction)),
    once(property_record(Database,Property,Record_Remainder)),
    apply_restriction_(Type,Class,Property,Database,
                       Restriction,Range,Record_Remainder,Frame).

/*
 * calculate_frame(+Class:uri,+Properties:list(uri),
 *                 +Restriction_Formula:property_restriction, Database:database -Frame) is det.
 *
 * Calculate the application of the restriction formula to the properties.
 */
calculate_frame(Class,Properties,Restriction_Formula,Database,Frames) :-
    calculate_frame_(Properties,Class,Restriction_Formula,Database,Frames).

calculate_frame_([],_Class,_Restriction_Formula,_Database,[]).
calculate_frame_([Property|Property_Rest],Class,Restriction_Formula,Database,[Property_Frame|Frame_Rest]) :-
    apply_restriction(Class,Property,Database,Restriction_Formula,Property_Frame),
    calculate_frame_(Property_Rest,Class,Restriction_Formula,Database,Frame_Rest).

/*
 * We can't actually check types here because tabling doesn't work with
 * attributed variables.
 *
 * class_frame_aux(+Class:uri,Database:databaseOutputFrame:frame) is semidet.
 * Generate the frame associated with a given class.
 *
 * Fails if the class doesn't exist.
 */
:- table class_frame/3.
class_frame(Class,Database,Frame) :-
    class_frame_aux(Class,Database,Frame).

class_frame_aux(Class, Database, Frame) :-
    (   class_formula(Class,Database,Formula)
    ->  restriction_formula(Formula,Database,RestrictionFormula),
        class_properties(Class,Database,Properties),
        debug(terminus(frame(restriction)),
              'Class: ~q~n Formula: ~q~n Properties ~q~n',[Class,Formula,Properties]),
        debug(terminus(frame(restriction)),'Restriction: ~p',[RestrictionFormula]),
        calculate_frame(Class,Properties,RestrictionFormula,Database,Frame)
    ;   Frame = [type=failure, message='No Class Formula!', class=Class]).

/**
 * fill_class_frame(+Elt,+Database,-Frame,-Filled) is det.
 *
 * Fill a class frame with values to recreate the LDO structure.
 *
 * NOTE: This should probably be upgraded to JSON-LD using dictionaries.
 */
fill_class_frame(_,_,[],[]) :- !.
fill_class_frame(Elt,Database,[[type=objectProperty|P]|Rest], Frames) :-
    % object property
    !,
    memberchk(property=Prop, P),
    once(select(frame=Frame,P,Pp)),
    Prefix=[type=objectProperty,domainValue=Elt|Pp],
    (   setof([frame=FilledFrame],
              V^(inferredEdge(Elt, Prop, V, Database),
                 fill_class_frame(V,Database,Frame,FilledFrame)),
              FrameSuffixes)
    ->  maplist(append(Prefix),FrameSuffixes,PrefixFrames),
        fill_class_frame(Elt,Database,Rest,F),
        append(PrefixFrames,F,Frames)
    ;   fill_class_frame(Elt,Database,Rest,Frames)).
fill_class_frame(Elt,Database,[[type=datatypeProperty|P]|Rest],Frames) :-
    % datatype property
    !,
    memberchk(property=Prop, P),
    Prefix = [type=datatypeProperty,domainValue=Elt|P],
    (   setof([rangeValue=V], inferredEdge(Elt, Prop, V, Database), Vs)
    ->  maplist(append(Prefix),Vs,PrefixFrames),
        fill_class_frame(Elt,Database,Rest,F),
        append(PrefixFrames,F,Frames)
    ;   fill_class_frame(Elt,Database,Rest,Frames)).
fill_class_frame(Elt,Database,[[type=restriction|_]|Rest],Frames) :-
    % a bare restriction (restricts nothing)
    !,
    fill_class_frame(Elt,Database,Rest,Frames).
fill_class_frame(Elt,Database,[type=class_choice,operands=Fs],Fsp_Filtered) :-
    % A class choice (the choice has already been made...)
    !,
    debug(terminus(frame(fill)), 'Elt: ~q~n', [Elt]),
    % Needs to be a principle class
    once(instance_class(Elt,Class,Database)),
    debug(terminus(frame(fill)), 'Class: ~q~n', [Class]),
    maplist({Elt,Database}/[Fin,Fout]>>(fill_class_frame(Elt,Database,Fin,Fout)),Fs,Fsp),
    debug(terminus(frame(fill)), 'Fsp: ~q~n', [Fsp]),
    include({Class}/[Frame]>>(
                forall(member(Prop_Frame,Frame),
                       member(domain=Class, Prop_Frame))
            ), Fsp, Filtered),
    debug(terminus(frame(fill)),'fill_class_frame/4 choice Filtered: ~q~n', [Filtered]),
    Filtered = [Fsp_Filtered].
fill_class_frame(Elt,Database,C,[type=Type,frames=Fsp]) :-
    memberchk(type=Type, C),
    memberchk(operands=Fs, C),
    % An operand
    !,
    maplist({Elt,Database}/[Fin,Fout]>>(fill_class_frame(Elt,Database,Fin,Fout)),Fs,Fsp).
fill_class_frame(Elt,_,F,DocumentFrame) :-
    memberchk(type=Type, F),
    memberchk(Type,[oneOf,document]),
    % Just need one type
    !,
    append(F,[domainValue=Elt],DocumentFrame).
fill_class_frame(Elt,DB,F,_) :-
    format(atom(M), 'Unable to process frame for frame filling rendering the predicate semi-deterministic. Results from: ~q~n', [fill_class_frame(Elt,DB,F,_)]),
    throw(error(M)).

choose_property(Database,Property,[type=and,operands=R], Result) :-
    member(F,R),
    !,
    choose_property(Database,Property,F,Result).
choose_property(Database,Property,[type=or,operands=R], Result) :-
    member(F,R),
    !,
    choose_property(Database,Property,F,Result).
choose_property(Database,Property,[type=xor,operands=R], Result) :-
    member(F,R),
    !,
    choose_property(Database,Property,F,Result).
choose_property(Database,P,[R|Rest], [R|Result]) :-
    member(property=Q,R),
    !,
    % Can this be correct?
    subsumption_properties_of(P,Q,Database), !,
    choose_property(Database,P,Rest,Result).
choose_property(Database,P,[R|FrameRest], Result) :-
    \+ (member(property=Q,R), subsumption_properties_of(P,Q,Database)),
    choose_property(Database,P,FrameRest,Result), !.
choose_property(_Database,_P,[], []) :- !.

% Property Frame
class_property_frame(Class, Property, Database, PropertyFrame) :-
    class_frame(Class, Database, Frame),
    choose_property(Database,Property,Frame,PropertyFrame).

% get filled frame for document
document_filled_frame(Document,Database,Filled) :-
    % Probably needs to be replaced with a "principle class"
    once(instance_class(Document,Class,Database)),
    class_frame(Class,Database,Frame),
    fill_class_frame(Document,Database,Frame,Filled).

/*
 * realiser(+Document:uri,+Frame:frame,+Database:database+Depth:number,-Realiser:any) is det.
 *
 * Synthesise the concrete representative of the schema class,
 * showing inhabitation unfolding documents up to a depth of Depth.
 *
 * Does not actually appear to be det!
 */
realiser(Elt,Frame,Database,Depth,['@type'=Class,
                                   '@id'=Elt
                                   |Realisers]) :-
    instance_class(Elt,Class,Database),
    realise_frame(Elt,Frame,Database,Depth,Realisers).

/*
 * realise_frame(Elt,Frame,Database,Depth,Quasi_JSONLD) is det.
 *
 * Traverse frame synthesising realisers.
 */
realise_frame(_,[],_,_,[]) :-
    !.
realise_frame(Elt,[[type=objectProperty|P]|Rest],Database,Depth,Realisers) :-
    !, % no turning back if we are an object property
    memberchk(property=Prop, P),
    once(select(frame=Frame,P,_FrameLessP)),
    (   setof(New_Realiser,
              V^(inferredEdge(Elt, Prop, V, Database),
                 (   document(V,Database)
                 ->  (   Depth =< 1
                     ->  New_Realiser=[V]
                     ;   New_Depth is Depth-1,
                         document_object(Database,V,New_Depth,Object),
                         Object = [_Type,_Id|New_Realiser])
                 ;   realiser(V,Frame,Database,Depth,New_Realiser))),
              RealiserValues)
    ->  (   RealiserValues = [Val]
        ->  Realisers = [Prop=Val|RealiserTail]
        ;   Realisers = [Prop=RealiserValues|RealiserTail]
        ),
        realise_frame(Elt,Rest,Database,Depth,RealiserTail)
    ;   realise_frame(Elt,Rest,Database,Depth,Realisers)
    ).
realise_frame(Elt,[[type=datatypeProperty|P]|Rest],Database,Depth,Realisers) :-
    !, % no turning back if we are a datatype property
    memberchk(property=Prop, P),
    (   setof(V,
              inferredEdge(Elt, Prop, V, Database),
              RealiserValues)
    ->  (   RealiserValues = [Val]
        ->  Realisers = [Prop=Val|RealiserTail]
        ;   Realisers = [Prop=RealiserValues|RealiserTail]
        ),
        realise_frame(Elt,Rest,Database,Depth,RealiserTail)
    ;   realise_frame(Elt,Rest,Database,Depth,Realisers)
    ).
realise_frame(Elt,[[type=restriction|_R]|Rest],Database,Depth,Realisers) :-
    % We are a bare restriction, not applied to any property
    !,
    realise_frame(Elt,Rest,Database,Depth,Realisers).
realise_frame(Elt,[[type=class_choice,operands=_]|Rest],Database,Depth,[Realiser|Realisers]) :-
    % We are a bare class_choice, not applied to any property
    !,
    document_object(Database,Elt,Depth,Realiser),
    realise_frame(Elt,Rest,Database,Depth,Realisers).
realise_frame(Elt,Frame,Database,Depth,Realisers) :-
    % We should be able to assume correctness of operator here...
    % member(type=Type, Frame),
    memberchk(operands=Fs, Frame),
    !, % We're an operator, so stick with it
    maplist({Elt,Database,Depth}/[TheFrame,New_Realiser]
            >>(realiser(Elt,TheFrame,Database,Depth,New_Realiser)),Fs,Realisers).
realise_frame(_Elt,F,_Database,_Depth,[]) :-
    memberchk(type=oneOf, F),
    !.
realise_frame(Elt, Frame, Database, Depth, New_Realiser) :-
    memberchk(type=document, Frame),
    (   Depth =< 1
    ->  New_Realiser=[]
    ;   New_Depth is Depth-1,
        document_object(Database,Elt,New_Depth,Object),
        Object = [_Type,_Id|New_Realiser]).

:- begin_tests(frame).
:- use_module(core(util/test_utils)).
:- use_module(library(http/json)).
:- use_module(core(query)).

test(class_frame, [blocked('not using frames yet')])
:-
    open_descriptor(system_descriptor{}, Database),
    class_frame('http://terminusdb.com/schema/system#Agent',Database,Frame),

    % Not sure how stable this order is.
    Frame = [[type=objectProperty,
              property='http://terminusdb.com/schema/system#role',
              domain='http://terminusdb.com/schema/system#Agent',
              range='http://terminusdb.com/schema/system#Role',
              restriction=true,
              frame=[type=document,class='http://terminusdb.com/schema/system#Role',label="Role"@en,comment="A role is a collection of capabilities that can be allocated to any user"@en],
              label="Has Role"@en,
              comment="A property that links an agent has a role"@en],
             [type=datatypeProperty,
              property='http://terminusdb.com/schema/system#agent_name',
              domain='http://terminusdb.com/schema/system#Agent',
              restriction=true,
              range='http://www.w3.org/2001/XMLSchema#string',
              label="Agent name"@en,
              comment="An name for API authentication"@en],
             [type=datatypeProperty,
              property='http://www.w3.org/2000/01/rdf-schema#label',
              domain='http://terminusdb.com/schema/system#Agent',
              restriction=true,
              range='http://www.w3.org/2001/XMLSchema#string'],
             [type=datatypeProperty,
              property='http://www.w3.org/2000/01/rdf-schema#comment',
              domain='http://terminusdb.com/schema/system#Agent',
              restriction=true,
              range='http://www.w3.org/2001/XMLSchema#string']].

test(document_filled_frame, [blocked('not using frames yet')])
:-
    open_descriptor(system_descriptor{}, Database),
    document_filled_frame('terminusdb:///system/data/admin',Database,Frame),

    Frame = [[type=datatypeProperty,
              domainValue='terminusdb:///system/data/admin',
              property='http://terminusdb.com/schema/system#user_key_hash',
              domain='http://terminusdb.com/schema/system#User',
              restriction=true,
              range='http://www.w3.org/2001/XMLSchema#string',
              label="User Key"@en,
              comment="A user key for API authentication"@en,
              rangeValue=_],
             [type=objectProperty,
              domainValue='terminusdb:///system/data/admin',
              property='http://terminusdb.com/schema/system#role',
              domain='http://terminusdb.com/schema/system#User',
              range='http://terminusdb.com/schema/system#Role',
              restriction=true,
              label="Has Role"@en,
              comment="A property that links an agent has a role"@en,
              frame=[type=document,
                     class='http://terminusdb.com/schema/system#Role',
                     label="Role"@en,
                     comment="A role is a collection of capabilities that can be allocated to any user"@en,
                     domainValue='terminusdb:///system/data/admin_role']],
             [type=datatypeProperty,
              domainValue='terminusdb:///system/data/admin',
              property='http://terminusdb.com/schema/system#agent_name',
              domain='http://terminusdb.com/schema/system#User',
              restriction=true,
              range='http://www.w3.org/2001/XMLSchema#string',
              label="Agent name"@en,
              comment="An name for API authentication"@en,
              rangeValue="admin"^^'http://www.w3.org/2001/XMLSchema#string'],
             [type=datatypeProperty,
              domainValue='terminusdb:///system/data/admin',
              property='http://www.w3.org/2000/01/rdf-schema#label',
              domain='http://terminusdb.com/schema/system#User',
              restriction=true,
              range='http://www.w3.org/2001/XMLSchema#string',
              rangeValue="Server Admin User"@en],
             [type=datatypeProperty,
              domainValue='terminusdb:///system/data/admin',
              property='http://www.w3.org/2000/01/rdf-schema#comment',
              domain='http://terminusdb.com/schema/system#User',
              restriction=true,
              range='http://www.w3.org/2001/XMLSchema#string',
              rangeValue="This is the server super user account"@en]].

:- end_tests(frame).

/*
 * realise_quads(Elt,Frame,Database,Realiser) is det.
 *
 * The triple realiser must be kept in complete lock step with the definition above.
 * This makes me wonder if we shouldn't keep the method fused or derived!
 *
 * It may be desirable to have a depth parameter here as well?
 */
realise_quads(_,[],_,[]) :-
    !.
realise_quads(Elt,[[type=objectProperty|P]|Rest],Database,[(G_Type_Desc,Elt,RDFType,Type)|Realiser]) :-
    !, % no turning back if we are an object property
    database_instance(Database,Gs),

    RDFType = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
    xquad(Gs,G_Type,Elt,RDFType,Type),
    G_Type_Desc = G_Type.descriptor,

    member(property=Prop, P),
    select(frame=Frame,P,_FrameLessP),
    (   setof(New_Realiser,
              V^(inferredQuad(G, Elt, Prop, V, Database),
                 (   is_dict(G)
                 ->  get_dict(descriptor,G,G_Desc)
                 ;   G = inferred
                 ->  G = G_Desc
                 ;   throw(error(unexpected_graph_object(G),_))),
                 (   document(V,Database)
                 ->  New_Realiser=[(G_Desc,Elt,Prop,V)]
                 ;   realise_quads(V,Frame,Database,Below),
                     New_Realiser=[(G_Desc,Elt,Prop,V)|Below])),
              RealiserLists)
    ->  append(RealiserLists,Realisers_on_P),
        realise_quads(Elt,Rest,Database,Realiser_Tail),
        append(Realisers_on_P, Realiser_Tail, Realiser)
    ;   realise_quads(Elt,Rest,Database,Realiser)
    ).
realise_quads(Elt,[[type=datatypeProperty|P]|Rest],Database,[(G_Type_Desc,Elt,RDFType,Type)|Realiser]) :-
    !, % no turning back if we are a datatype property
    database_instance(Database,Gs),

    RDFType = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
    xquad(Gs,G_Type,Elt,RDFType,Type),
    G_Type_Desc = G_Type.descriptor,

    member(property=Prop, P),
    (   setof((G_Desc,Elt,Prop,V),
              V^(   inferredQuad(G, Elt, Prop, V, Database),
                    (   is_dict(G)
                    ->  get_dict(descriptor,G,G_Desc)
                    ;   G = inferred
                    ->  G = G_Desc
                    ;   throw(error(unexpected_graph_object(G),_)))
                ),
              Realisers_on_P)
    ->  realise_quads(Elt,Rest,Database,Realiser_Tail),
        append(Realisers_on_P,Realiser_Tail,Realiser)
    ;   realise_quads(Elt,Rest,Database,Realiser)
    ).
realise_quads(Elt,[[type=restriction|_R]|Rest],Database,Realiser) :-
    % We are a bare restriction, not applied to any property
    !,
    realise_quads(Elt,Rest,Database,Realiser).
realise_quads(Elt,[[type=class_choice,operands=_]|Rest],Database,Realiser) :-
    % We are a bare class choice, not applied to any property
    !,
    object_edges(Elt,Database,Edges),
    realise_quads(Elt,Rest,Database,Realiser_Tail),
    append(Edges,Realiser_Tail,Realiser).
realise_quads(Elt,Frame,Database,Realisers) :-
    % We should be able to assume correctness of operator here...
    % member(type=Type, Frame),
    member(operands=Fs, Frame),
    !, % We're an operator, so stick with it
    maplist({Elt,Database}/[TheFrame,New_Realiser]
            >>(realise_quads(Elt,TheFrame,Database,New_Realiser)),Fs,Realiser_List),
    append(Realiser_List,Realisers).
realise_quads(_Elt,F,_Database,[]) :-
    member(type=Type, F),
    member(Type,[oneOf,document]),
    % is a one-of or document (don't backtrack over member)
    !.

/*
 * document_object(+DB:database,+Document:uri,+Depth,-Realiser) is semidet.
 *
 * Gets the realiser for the frame associated with the class of
 * Document
 */
document_object(DB, Document, Depth, Realiser) :-

    most_specific_type(Document,Class,DB),
    class_frame(Class,DB,Frame),

    % TODO: There really should not be epic loads of
    % choice points placed by realiser, but apparently
    % there are...
    once(realiser(Document,Frame,DB,Depth,Realiser)).

/*
 * document_jsonld(+Query_Context,+Document,-Realiser) is semidet.
 *
 * Gets the realiser for the frame associated with the class of
 * Document in a JSON_LD format using a supplied context.
 */
document_jsonld(Query_Context, Document, JSON_LD) :-
    document_jsonld(Query_Context, Document, 1, JSON_LD).

/*
 * document_jsonld(+Query_Context,+Document:uri,+Depth,-Realiser) is semidet.
 *
 * Gets the realiser for the frame associated with the class of
 * Document in a JSON-LD format using a supplied context and unfolding
 * up to depth Depth
 */
document_jsonld(Query_Context, Document, Depth, JSON_LD) :-
    Descriptor = (Query_Context.default_collection),
    collection_descriptor_prefixes(Descriptor, Prefixes),
    query_default_collection(Query_Context, Collection),
    prefix_expand(Document,Prefixes,Document_Ex),
    document_object(Collection, Document_Ex, Depth, Realiser),
    term_jsonld(Realiser, JSON_Ex),
    compress(JSON_Ex,Prefixes,JSON_LD).

/*
 * class_frame_jsonld(Query_Context,Class,JSON_Frame) is det.
 *
 */
class_frame_jsonld(Query_Context,Class,JSON_Frame) :-
    query_default_collection(Query_Context, Collection),
    class_frame(Class,Collection,Frame),
    term_jsonld(['@type'='system:Frame', 'system:properties'=Frame],JSON_LD),
    compress(JSON_LD, Query_Context.prefixes, JSON_Frame).

/*
 * filled_frame_jsonld(Query_Context,Class,JSON_Frame) is det.
 *
 */
filled_frame_jsonld(Query_Context,Class,JSON_Frame) :-
    query_default_collection(Query_Context, Collection),
    document_filled_frame(Class,Collection,Frame),
    term_jsonld(['@type'='system:FilledFrame', 'system:properties'=Frame],JSON_LD),
    compress(JSON_LD, Query_Context.prefixes, JSON_Frame).

/*
 * object_edges(URI,Database,Edges) is det.
 *
 * Is there any way to make this so that everyting is derived from
 * the same source?
 */
object_edges(URI,Database,Edges) :-
    (   most_specific_type(URI,Class,Database),
        class_frame(Class,Database,Frame),
        realise_quads(URI,Frame,Database,Unsorted),
        sort(Unsorted,Edges)
    ->  true
    % There is no type in the database, so it doesn't exist...
    ;   Edges=[]).


/*
 * object_references(URI,Database,Edges) is det.
 *
 * Get the set of references to a given object.
 */
object_references(URI,Database,Edges) :-
    findall((G_Desc,Elt,Prop,URI),
            (   inferredQuad(G, Elt, Prop, URI, Database),
                (   is_dict(G)
                ->  get_dict(descriptor,G,G_Desc)
                ;   G = inferred
                ->  G = G_Desc
                ;   throw(error(unexpected_graph_object(G, context(realise_quads/4, _)))))),
            Edges).

/*
 * object_instance_graph(JSON_or_URI,Database,I) is det.
 */
object_instance_graph(URI,Database,I) :-
    atom(URI),
    !,
    database_instance(Database,Instance),
    member(I,Instance),
    % Defo exists here.
    (   xrdf([I],URI,rdf:type,_)
    ->  true).
object_instance_graph(JSON,Database,I) :-
    is_dict(JSON),
    get_dict('@id', JSON, URI),
    object_instance_graph(URI,Database,I).

/*
 * delete_object(URI,Query_Context) is det.
 *
 */
delete_object(URI,Query_Context) :-
    Ctx = (Query_Context.prefixes),
    query_default_collection(Query_Context, Database),
    prefix_expand(URI,Ctx,URI_Ex),
    object_edges(URI_Ex,Database,Object_Edges),
    object_references(URI_Ex,Database,References),

    debug(terminus(frame(delete)),'~n[Delete] References: ~q~n', [References]),
    debug(terminus(frame(delete)),'~n[Delete] Edges: ~q~n', [Object_Edges]),

    union(Object_Edges,References,Edges),
    exclude([(inferred,_,_,_)]>>true, Edges, Non_Inferred_Edges),
    Transaction_Objects = (Query_Context.transaction_objects),
    delete_edges(Non_Inferred_Edges, Transaction_Objects).

delete_edges([],_).
delete_edges([(G_Desc,X,Y,Z)|Edges], Transaction_Objects) :-
    graph_descriptor_transaction_objects_read_write_object(
        G_Desc,
        Transaction_Objects,
        G),
    delete(G,X,Y,Z,_N),
    delete_edges(Edges, Transaction_Objects).


insert_edges([],_).
insert_edges([(G_Desc,X,Y,Z)|Edges], Transaction_Objects) :-
    graph_descriptor_transaction_objects_read_write_object(
        G_Desc,
        Transaction_Objects,
        G),
    insert(G,X,Y,Z,_N),
    insert_edges(Edges, Transaction_Objects).

type_to_type_word(Type, Type_Word) :-
    pattern_string_split('#', Type, Segments),
    append(_, [Type_Word], Segments).

/*
 * update_object(Obj:dict,Query_Context) is det.
 *
 * This should extract the object from the database
 * and set up inserts / deletes as:
 *
 * Inserts := triples(New) / triples(Old)
 * Deletes := triples(New) / triples(New)
 */
update_object(Obj, Query_Context) :-
    (   jsonld_id(Obj,ID)
    ->  true
    ;   jsonld_type(Obj, Full_Type),
        type_to_type_word(Full_Type, Type),
        get_dict(doc, Query_Context.prefixes, Doc_Prefix),
        random_idgen(Doc_Prefix, [Type], ID)),
    update_object(ID,Obj,Query_Context).

/*
 * update_object(ID:url,Obj:dict,Query_Context) is det.
 *
 * Does the actual updating using ID.
 */
update_object(ID, Obj, Query_Context) :-
    Prefixes = (Query_Context.prefixes),
    prefix_expand(ID,Prefixes,ID_Ex),

    put_dict('@id', Obj, ID_Ex, New_Obj),

    jsonld_triples(New_Obj,Prefixes,New_Triples),

    query_default_collection(Query_Context, Database),
    object_edges(ID,Database,Old_Quads),

    debug(terminus(frame(update)),'~n[Update] New: ~q~n', [New_Triples]),
    debug(terminus(frame(update)),'~n[Update] Old: ~q~n', [Old_Quads]),

    % Don't back out now.  both above should be det so we don't have to do this.
    !,
    query_default_write_graph(Query_Context, Write_Graph),
    WG_Desc = (Write_Graph.descriptor),
    % don't insert any edge which already exists in any instance graph
    convlist({WG_Desc,Old_Quads}/[(X,Y,Z),(WG_Desc,X,Y,Z)]>>(
                 \+ member((_G,X,Y,Z),Old_Quads)
             ),
             New_Triples,
             Inserts),
    % don't delete any edge which is not in *some* graph,
    % but if it is there delete it in the graph in which it exists.
    convlist({New_Triples}/[(G,X,Y,Z),(G,X,Y,Z)]>>(
                 \+ member((X,Y,Z),New_Triples)
             ),
             Old_Quads,
             Deletes),

    Transaction_Objects = (Query_Context.transaction_objects),
    insert_edges(Inserts, Transaction_Objects),
    delete_edges(Deletes, Transaction_Objects).

/*
 * document_filled_class_frame_jsonld(+Document:uri,+Ctx:any,+Database:database,-FilleFrame_JSON)
 *    is semidet.
 *
 * Gets the realiser for the frame associated with the class of
 * Document in a JSON_LD format using a supplied context.
 */
document_filled_class_frame_jsonld(Document,Ctx,Database,JSON_LD) :-
    document_filled_frame(Document, Database, FCF),
    term_jsonld(FCF, JSON_Ex),

    merge_dictionaries(Ctx,Database.prefixes,Ctx_Total),

    compress(JSON_Ex,Ctx_Total,JSON_LD).

:- begin_tests(documents).
:- use_module(core(util/test_utils)).
:- use_module(library(http/json)).
:- use_module(core(query)).

test(update_object,
     [setup((setup_temp_store(State))),
      cleanup(teardown_temp_store(State))
     ])
:-

    Descriptor = system_descriptor{},

    open_descriptor(Descriptor, Transaction),
    create_context(Transaction, Query),

    Document = _{'@context': Query.prefixes,
                 '@id' : "doc:new_user",
                 '@type' : "system:User",
                 'rdfs:comment': _{'@language': "en",
                                   '@value': "This is a test user."},
                 'rdfs:label': _{'@language':"en",
                                 '@value':"Test User"},
                 'system:user_key_hash':
                 _{'@type':"xsd:string",
                   % key = 'test'
                   '@value': "$pbkdf2-sha512$t=131072$hM+ItUnA7Xmvc+Wbk9Bl4Q$3FSf1OfkofmGltr+yiN65d58Ab0guGpW1jeVbpVF8c6pc9mT3UDUTx0TXjEBFDOtjE9lm2wMLttGXD9aDekECA"
                 },
                 'system:agent_name': _{'@type':"xsd:string",
                                        '@value':"test"
                                         },
                 'system:role': _{'@id':"doc:admin_role",
                                  '@type':"system:Role"}
                },

    update_object(Document, Query),
    %retry_transaction(Query_Out),
    run_transactions(Query.transaction_objects, true, _Meta_Data),

    open_descriptor(Descriptor, Transaction2),
    create_context(Transaction2, Query2),
    document_jsonld(Query2, "doc:new_user", 1, JSON_LD),

    _{'@id':'doc:new_user'} :< JSON_LD.

test(document_jsonld_depth, [])
:-
    Descriptor = system_descriptor{},
    User_ID = 'terminusdb:///system/data/admin',

    open_descriptor(Descriptor, Transaction),
    create_context(Transaction, Query),
    document_jsonld(Query, User_ID, 1, JSON_LD),
    % TODO: Why are these atoms? Inconsistent!
    _{'@id':'doc:admin','@type':'system:User'} :< JSON_LD.


test(delete_object, [
         setup((setup_temp_store(State))),
         cleanup(teardown_temp_store(State))
     ])
:-

    Descriptor = system_descriptor{},

    open_descriptor(Descriptor, Transaction),
    create_context(Transaction, Query),

    Document = _{'@context': Query.prefixes,
                 '@id' : "doc:new_user",
                 '@type' : "system:User",
                 'rdfs:comment': _{'@language': "en",
                                   '@value': "This is a test user."},
                 'rdfs:label': _{'@language':"en",
                                 '@value':"Test User"},
                 'system:user_key_hash':
                 _{'@type':"xsd:string",
                   % key = 'test'
                   '@value': "$pbkdf2-sha512$t=131072$hM+ItUnA7Xmvc+Wbk9Bl4Q$3FSf1OfkofmGltr+yiN65d58Ab0guGpW1jeVbpVF8c6pc9mT3UDUTx0TXjEBFDOtjE9lm2wMLttGXD9aDekECA"
                 },
                 'system:agent_name': _{'@type':"xsd:string",
                                        '@value':"test"
                                       },
                 'system:role': _{'@id':"doc:admin_role",
                                  '@type':"system:Role"}
                },

    update_object(Document, Query),
    %retry_transaction(Query_Out),
    run_transactions(Query.transaction_objects, true, _Meta_Data1),

    create_context(Descriptor, Query_Context),

    delete_object("doc:new_user",Query_Context),
    run_transactions(Query_Context.transaction_objects, true, _Meta_Data2),

    create_context(Descriptor, Query_Context2),

    \+ document_jsonld(Query_Context2, "doc:new_user", 1, _JSON).

:- end_tests(documents).
