##About##

This document defines the structured data layer that Cockroach exposes on top of
its distributed key:value datastore.

##Overview##

The structured data layer is an abstraction over the internal key:value store
that provides familiar data organization tools. The structured data layer
implements a tabular model of data storage which somewhat resembles a relational
database at a high level. The terms namespace, table, column, and index/key
collectively define the structured data abstraction, each roughly akin to
database, table, column, and index/key in a relational database. The structured
data layer, when complete, introduces concepts of data storage that many
database users are familiar with, and greatly increases the range of use-cases
that Cockroach is able to ergonomically service.

##Goals##

Add support for the following entities: <i>namespaces, tables, columns, and
indexes</i>. These notions are chosen for their similarity to <i>databases, tables,
columns, and indexes</i> in relational databases, but they are not intended to be
implementations thereof. Each entity will support:

- Creation: of a namespace, table, column in O(1).

- Renaming: in O(1) Most configuration changes in O(1): A change in permissions
  for instance, will be in O(1) time. Adding a new index will take O(n) time,
where n is the number of rows in the table.

- Deletion: in O(n) where n is the number of subordinate entities (tables for a
  namespace, rows for a table).

The client API will be changed to use tabular based addressing instead of
global-key addressing. Non-primary-keyed queries will be supported through the use of secondary indexes.

##Non-Goals##

For now we don't intend developing the following:

- Add support for triggers, stored-procedures, and integrity constraints

- Add the notion of column types beyond <i>a sequence of bytes</i>. Add support for
  unbounded sub-collections of columns.

- Add support for non-tabular storage. This might be supported in the future.

- Add support for column locality-groups to improve data layout for performance.

## Design ##

We support high level entities like Namespace, Table, Index, and Column.
{Namespace,Table}Descriptor stores the entity metadata for {Namespace,Table}.

<pre>
 <code>NamespaceDescriptor {
         NamespaceID = … ,
         Permissions = …,
         ...}</code>

 <code>TableDescriptor {
         TableID = …,
         Columns = [{ ColumnID = …, Name = ... }, ...],
         Indexes = [{ IndexID = …, Name = …, ColumnIDs = [ … ]}, ...],
         Permissions = …
         NextFreeColumnId = …
         NextFreeIndexID = ...,
         ...}</code>
</pre>

In order to support fast renaming, we indirect entity access through a
hierarchical name-to-identifier mapping. NamespaceID and TableID are
allocated from the same global ID space. ColumnID and IndexID are local
to each Table.

To simplify our implementation, our Tables will require the presence of a
primary key. Follow-up work may relax this requirement. An investigation of use
cases not requiring a primary key is required to specify this work. A cell in
the Table can be addressed for a particular Column and Row.

Initially, all the Table metadata in a cluster will be distributed by gossip and
cached by each cockroach node. To reduce contention on the Table metadata, a
database transaction on the data within a Table will only contain the data being
addressed, and will not include a database read of the Table metadata. Care will
be taken to not expose these implementation details to the user.

##Addressing: Anatomy of a key##

The “/” separators used below are shorthand for ordered encoding of the
separated values.

*Global metadata keys*

The root namespace is an unnamed namespace with a fixed ID of 0. Within it,
metadata addressing will work as follows:

Namespace: `\x00ns<NamespaceName>` -> NamespaceDescriptor { NamespaceID = …, ...}

Table: `\x00tbl<NamespaceID><TableName>` -> TableDescriptor { TableID = …,
local-IDs, … }

Creating/Renaming/Deleting: Creating a new Namespace or Table involves
allocating a new ID, initializing the {Namespace,Table}Descriptor, and storing
the descriptor at key:/parent-id/name. Renaming involves deleting the
`/old-parent-id/old-name` and creating `/new-parent-id/new-name`. A namespace can
only be deleted if it does not contain any children. A table is deleted by
marking it deleted in its table descriptor. This will allow folks to recover
their data for a few days/weeks before we garbage collect the table in the
background.

**Data addressing**

An Index consists of keys with the following prefix: `/TableID/IndexID/Key>`, where
TableID represents the Table being addressed and IndexID the index in use.

**Primary key addressing**

This schema is made possible by the uniqueness constraint inherent to primary
keys. The use of a primary key prefix: `/TableID/PrimaryIndexID/Key`, keys into a
unique row in the database. A cell within a row under a particular column will
be addressed by suffixing the desired ColumnID:
`/TableID/PrimaryIndexID/Key/ColumnID`.  PrimaryIndexID is variable to allow
changing the primary key.

**Secondary key addressing**

Secondary keys will be implemented as a layer of indirection to the primary
keys. Unlike primary keys, secondary keys are not required to be unique.  So we
will employ the following key anatomy that address null values:
`/TableID/SecondaryIndexID/SecondaryKey/PrimaryKey`. Thus, multiple PrimaryKeys
can be enumerated under a single SecondaryKey. A lookup will involve looking up
the secondary index using the secondary key to pick up all the primary keys, and
further using the primary keys to get to all the data rows. A row insertion
involves: computing the primary and secondary keys for the row, adding the data
under the primary key, and adding the primary key to all the secondary indexes
under the secondary keys.

**Interleaved table layout**

We will not be implementing interleaved tables initially but it’s worth
discussing how we might arrange their data. Imagine you have two tables A and B
with B configured to be interleaved within A. The `/TableID-A/PrimaryIndexID/Key`
prefix determines the key prefix where the data from table B will be stored
along with an entire row from table A at primary key Key. All the rows from
table B will bear the prefix `/TableID-A/PrimaryIndexID/Key/TableID-B`, with
`/TableID-A/PrimaryIndexID/Key/TableID-B/KeyB` being a prefix for a particular row
in the table.

##Examples##

**Employee DB**

To represent an employee table for employees at microsoft, an admin might define
a namespace=“microsoft” with a table=”employees”. The employee table might have
columns (id, first-name, last-name, address, state, zip, telephone, etc), where
id is specified as the primary key. Under the covers the “microsoft” namespace
might be given a NamespaceID=101, and the employee table given a TableID=9876.
The primary index has a default IndexID=0 and there could be a secondary index
on lastname with IndexID=1. Column telephone might have a columnID=6. For an
employee with employee-id=3456, the employee’s telephone can be queried/modified
through the API using the query:
<pre>
 <code>{ table: “/microsoft/employees”,
         key: “3456”,
         columns : [“telephone” }</code>
</pre>
The query is converted internally by cockroach into a global key: /9876/0/3456/6
(`/TableID/PrimaryIndexID/Key/ColumnID`).

Assume a secondary index is built for the last-name column. Telephone numbers of
employees with lastname=”kimball” can be queried using the query:
<pre>
 <code>{ table: “/microsoft/employees”,
         index: “last-name”,
         key: “kimball”,
         columns: [“telephone”] }</code>
</pre>
and this might produce two records for Spencer and Andy. Internally cockroach
looks up the secondary index using key prefix:
`/TableID/SecondaryIndexID/Key`=/9876/1/kimball to get to the two employee ids for
Spencer and Andy, viz.: 1234 and 2345. The two telephone numbers are looked up
using keys: /9876/0/1234/6 and /9876/0/2345/6.

**Key:Value DB**

 It is important to note that a key-value store is simply a degenerate case of
the more fully-featured namespace & table based schema defined here. A user
interested in using cockroach as a key:value store to store all their documents
keyed by a document-id might define a table=“documents” under
namespace=”published”, with a column “document”. The user can lookup/modify the
database documents using the tuple (“/published/documents”, document-id,
“document”).

**Accounting/Permissions/Zones**

Cockroach currently allows a user to configure accounting, read/write
permissions, and zones by a key prefix. We will allow the user to configure
these permissions, etc, per namespace and per table.

**API**

The cockroach API will be a protobuf service API. The read API will support a
Get() on a key filtered on a group of columns. It will also support a Scan() of
multiple rows in a table into a stream of ResultSets. The client API written in
a particular language can export iterators over a ResultSet. The write API will
support Put() on a group of cells in a group of rows.

