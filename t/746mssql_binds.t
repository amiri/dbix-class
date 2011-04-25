use strict;
use warnings;

# use this if you keep a copy of DBD::Sybase linked to FreeTDS somewhere else
BEGIN {
  if (my $lib_dirs = $ENV{DBICTEST_MSSQL_PERL5LIB}) {
    unshift @INC, $_ for split /:/, $lib_dirs;
  }
}

use Test::More;
use Test::Exception;
use Try::Tiny;
use Scope::Guard ();
use lib qw(t/lib);
use DBICTest;

my ($dsn,  $user,  $pass)  = @ENV{map { "DBICTEST_MSSQL_${_}"      } qw/DSN USER PASS/};
my ($dsn2, $user2, $pass2) = @ENV{map { "DBICTEST_MSSQL_ODBC_${_}" } qw/DSN USER PASS/};
my ($dsn3, $user3, $pass3) = @ENV{map { "DBICTEST_MSSQL_ADO_${_}"  } qw/DSN USER PASS/};

plan skip_all => <<'EOF' unless $dsn || $dsn2 || $dsn3;
Set $ENV{DBICTEST_MSSQL_DSN} and/or $ENV{DBICTEST_MSSQL_ODBC_DSN} and/or
$ENV{DBICTEST_MSSQL_ADO_DSN} _USER and _PASS to run these tests.

WARNING: these tests create and drop the table mssql_types_test.
EOF

DBICTest::Schema->load_classes('MSSQLTypes');

my @connect_info = (
#  [ $dsn,  $user,  $pass,  {} ],
  [ $dsn2, $user2, $pass2, {} ],
#  [ $dsn3, $user3, $pass3, {} ],
);

# also test with dynamic cursors if testing ODBC
#push @connect_info, [ $dsn2, $user2, $pass2, {
#  on_connect_call => 'use_dynamic_cursors'
#}] if $dsn2;

my $schema;

foreach my $conn_idx (0..$#connect_info) {
  my ($dsn, $user, $pass, $opts) = @{ $connect_info[$conn_idx] || [] };

  next unless $dsn;

  $schema = DBICTest::Schema->connect($dsn, $user, $pass, $opts);

  my $sg = Scope::Guard->new(\&cleanup);

  my $ver = $schema->storage->_server_info->{normalized_dbms_version} || 0;

  $schema->storage->dbh_do(sub {
    my ($storage, $dbh) = @_;
    local $^W = 0; # for ADO
    $dbh->do(<<'EOF');
IF OBJECT_ID('mssql_types_test', 'U') IS NOT NULL DROP TABLE mssql_types_test
EOF
    $dbh->do(<<"EOF");
CREATE TABLE mssql_types_test (
  id int identity primary key,
  bigint_col bigint,
  smallint_col smallint,
  tinyint_col tinyint,
  money_col money,
  smallmoney_col smallmoney,
  bit_col bit,
  real_col real,
  double_precision_col double precision,
  numeric_col numeric,
  decimal_col decimal,
  datetime_col datetime,
  smalldatetime_col smalldatetime,
  char_col char(3),
  varchar_col varchar(100),
  nchar_col nchar(3),
  nvarchar_col nvarchar(100),
  binary_col binary(4),
  varbinary_col varbinary(100),
  text_col text,
  ntext_col ntext,
  image_col image,
  uniqueidentifier_col uniqueidentifier,
  sql_variant_col sql_variant,
  xml_col xml,
@{[ $ver >= 10 ? '
  date_col date,
  time_col time,
  datetimeoffset_col datetimeoffset,
  datetime2_col datetime2,
  hierarchyid_col hierarchyid
' : '
  date_col varchar(100),
  time_col varchar(100),
  datetimeoffset_col varchar(100),
  datetime2_col varchar(100),
  hierarchyid_col varchar(100)
' ]}
)
EOF
  });

  my %data = (
    bigint_col => 33,
    smallint_col => 22,
    tinyint_col => 11,
# Causes "Cannot convert a char value to money. The char value has incorrect
# syntax" on populate.
#    money_col => '55.5500',
#    smallmoney_col => '44.4400',
    bit_col => 1,
    real_col => '66.666',
    double_precision_col => '77.777000000000001',
    numeric_col => 88,
    decimal_col => 99,
    datetime_col => '2011-04-25 09:37:37.377',
    smalldatetime_col => '2011-04-25 09:38:00',
    char_col => 'foo',
    varchar_col => 'bar',
    nchar_col => 'baz',
    nvarchar_col => 'quux',
    text_col => 'text',
    ntext_col => 'ntext',
# Binary types cause "implicit conversion...is not allowed" errors on
# identity_insert, and "Invalid character value for cast speicification" on
# populate.
#    binary_col => "\0\1\2\3",
#    varbinary_col => "\4\5\6\7",
#    image_col => "\10\11\12\13",
    uniqueidentifier_col => '966CD933-6C4C-1014-9F40-FB912B1D7AB5',
# "Operand type clash: sql_variant is incompatible with text (SQL-22018)"
# from MS ODBC driver.
#    sql_variant_col => 'sql_variant',
# needs a CAST in _select_args, otherwise select causes
# "String data, right truncation"
# With LongTruncOk, it looks like binary data is returned.
#    xml_col => '<foo>bar</foo>',
    date_col => '2011-04-25',
# need to bind with full .XXXXXXX precision
    time_col => '09:43:43.0000000',
    datetimeoffset_col => '2011-04-25 09:37:37.0000000 -05:00',
# this one allows full precision for some reason
    datetime2_col => '2011-04-25 09:37:37.3777777',
# needs a CAST in _select_args
#    hierarchyid_col => '/',
  );

  my $rs = $schema->resultset('MSSQLTypes');

  my %search = %data;
  # blob cols cannot be compared to with =
  delete @search{qw/image_col text_col ntext_col/};

  # try regular insert
  {
    lives_ok {
      $rs->create(\%data)
    } 'regular insert survived';

    ok ((my $row = try { $rs->search(\%search)->first }),
      'retrieved inserted row for regular insert');

    my %retrieved = $row ? $row->get_columns : ();
    delete @retrieved{qw/id/};

    # delete columns we did not insert for whatever reason
    while (my ($k, $v) = each %retrieved) {
      delete $retrieved{$k} if not defined $v;
    }

    is_deeply \%retrieved, \%data,
      'retrieved data for regular insert matches inserted data';
  }

  $rs->delete;

  # do an identity insert
  {
    lives_ok {
      $rs->create({ %data, id => 1 })
    } 'identity insert survived';

    ok ((my $row = try { $rs->search(\%search)->first }),
      'retrieved inserted row for identity insert');

    my %retrieved = $row ? $row->get_columns : ();

    # delete columns we did not insert for whatever reason
    while (my ($k, $v) = each %retrieved) {
      delete $retrieved{$k} if not defined $v;
    }

    is_deeply \%retrieved, { %data, id => 1 },
      'retrieved data for identity insert matches inserted data';
  }

  $rs->delete;

  # do a populate (insert_bulk)
  {
    lives_ok {
      $rs->populate([ \%data ])
    } 'populate survived';

    ok ((my $row = try { $rs->search(\%search)->first }),
      'retrieved inserted row for populate');

    my %retrieved = $row ? $row->get_columns : ();
    delete @retrieved{qw/id/};

    # delete columns we did not insert for whatever reason
    while (my ($k, $v) = each %retrieved) {
      delete $retrieved{$k} if not defined $v;
    }

    is_deeply \%retrieved, \%data,
      'retrieved data for populate matches inserted data';
  }

  $rs->delete;

  # do a populate (insert_bulk) with identity insert
  {
    lives_ok {
      $rs->populate([ { %data, id => 1 } ])
    } 'populate with identity insert survived';

    ok ((my $row = try { $rs->search(\%search)->first }),
      'retrieved inserted row for populate with identity insert');

    my %retrieved = $row ? $row->get_columns : ();

    # delete columns we did not insert for whatever reason
    while (my ($k, $v) = each %retrieved) {
      delete $retrieved{$k} if not defined $v;
    }

    is_deeply \%retrieved, { %data, id => 1 },
      'retrieved data for populate with identity insert matches inserted data';
  }
}

done_testing;

sub cleanup {
  if (my $dbh = eval { $schema->storage->dbh }) {
    local $^W = 0; # for ADO
    $dbh->do(<<'EOF');
IF OBJECT_ID('mssql_types_test', 'U') IS NOT NULL DROP TABLE mssql_types_test
EOF
  }
}
# vim:sts=2 sw=2 et:
