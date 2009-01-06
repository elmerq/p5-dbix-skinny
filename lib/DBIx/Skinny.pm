package DBIx::Skinny;
use strict;
use warnings;

our $VERSION = '0.01';

use DBI;
use DBIx::Skinny::Iterator;
use DBIx::Skinny::DBD;
use DBIx::Skinny::SQL;
use DBIx::Skinny::Row;
use DBIx::Skinny::Profiler;

sub import {
    my ($class, %opt) = @_;

    my $caller = caller;
    my $args   = $opt{setup};

    my $schema = "$caller\::Schema";
    eval "use $schema"; ## no critic
    die $@ if $@;

    my $dbd_type;
    if ($args->{dbh}) {
        $dbd_type = $args->{dbh}->{Driver}->{Name};
    } else {
        (undef, $dbd_type,) = DBI->parse_dsn($args->{dsn}) or die "can't parse DSN";
    }

    my $_attribute = +{
        dsn             => $args->{dsn},
        username        => $args->{username},
        password        => $args->{password},
        connect_options => $args->{connect_options},
        dbh             => $args->{dbh}||'',
        dbd             => DBIx::Skinny::DBD->new($dbd_type),
        schema          => $schema,
        profiler        => DBIx::Skinny::Profiler->new,
    };

    {
        no strict 'refs';
        *{"$caller\::attribute"} = sub { $_attribute };

        my @functions = qw/
            schema profiler
            dbh _connect
            call_schema_trigger
            do resultset search single search_by_sql count
                _get_iterator _mk_row_class
            insert bulk_insert create update delete find_or_create find_or_insert
                _add_where
            _execute _close_sth
        /;
        for my $func (@functions) {
            *{"$caller\::$func"} = \&$func;
        }
    }

    strict->import;
    warnings->import;
}

sub schema { shift->attribute->{schema} }
sub profiler { shift->attribute->{profiler} }

#--------------------------------------------------------------------------------
# db handling
sub _connect {
    my $class = shift;
    $class->attribute->{dbh} ||= DBI->connect(
        $class->attribute->{dsn},
        $class->attribute->{username},
        $class->attribute->{password},
        { RaiseError => 1, PrintError => 0, AutoCommit => 1, %{ $class->attribute->{connect_options} || {} } }
    );
    $class->attribute->{dbh};
}

sub dbh { shift->_connect }

#--------------------------------------------------------------------------------
# schema trigger call
sub call_schema_trigger {
    my ($class, $trigger, $table, $args) = @_;
    $class->schema->call_trigger($class, $table, $trigger, $args);
}

#--------------------------------------------------------------------------------
sub do {
    my ($class, $sql) = @_;
    $class->dbh->do($sql);
}

sub count {
    my ($class, $table, $args, $where) = @_;

    my $rs = $class->resultset(
        {
            from   => [$table],
        }
    );

    my ($alias, $column) = each %$args;
    $rs->add_select("COUNT($column)" =>  $alias);
    $class->_add_where($rs, $where);

    $rs->retrieve->first;
}

sub resultset {
    my ($class, $args) = @_;
    $args->{skinny} = $class;
    DBIx::Skinny::SQL->new($args);
}

sub search {
    my ($class, $table, $where, $opt) = @_;

    my $cols = $opt->{select} || $class->schema->schema_info->{$table}->{columns};
    my $rs = $class->resultset(
        {
            select => $cols,
            from   => [$table],
        }
    );

    $class->_add_where($rs, $where);

    $rs->limit(   $opt->{limit}   ) if $opt->{limit};
    $rs->offset(  $opt->{offset}  ) if $opt->{offset};

    if (my $terms = $opt->{order_by}) {
        my @orders;
        for my $term (@{$terms}) {
            my ($col, $case) = each %$term;
            push @orders, { column => $col, desc => $case };
        }
        $rs->order(\@orders);
    }

    if (my $terms = $opt->{having}) {
        for my $col (keys %$terms) {
            $rs->add_having($col => $terms->{$col});
        }
    }

    $rs->retrieve;
}

sub single {
    my ($class, $table, $where, $opt) = @_;
    $opt->{limit} = 1;
    $class->search($table, $where, $opt)->first;
}

sub search_by_sql {
    my ($class, $sql, $bind, $opt_table_info) = @_;

    $class->profiler->record_query($sql);
    my $sth = $class->_execute($sql, $bind);
    return $class->_get_iterator($sql, $sth, $opt_table_info);
}

sub _get_iterator {
    my ($class, $sql, $sth, $opt_table_info) = @_;

    return DBIx::Skinny::Iterator->new(
        skinny         => $class,
        sth            => $sth,
        row_class      => $class->_mk_row_class($sql),
        opt_table_info => $opt_table_info
    );
}

sub _mk_row_class {
    my ($class, $sql) = @_;

    my $row_class = 'DBIx::Skinny::Row::C';
    for my $i (0..(int(length($sql) / 8))) {
        $row_class .= crypt(substr($sql,($i*8),8), 'mk');
    }
    { no strict 'refs'; @{"$row_class\::ISA"} = ('DBIx::Skinny::Row'); }

    return $row_class;
}

*create = \*insert;
sub insert {
    my ($class, $table, $args) = @_;

    $class->call_schema_trigger('pre_insert', $table, $args);

    # deflate
    for my $col (keys %{$args}) {
        $args->{$col} = $class->schema->call_deflate($col, $args->{$col});
    }

    my (@cols,@bind);
    for my $col (keys %{ $args }) {
        push @cols, $col;
        push @bind, $class->schema->utf8_off($col, $args->{$col});
    }

    # TODO: INSERT or REPLACE. bind_param_attributes etc...
    my $sql = "INSERT INTO $table\n";
    $sql .= '(' . join(', ', @cols) . ')' . "\n" .
            'VALUES (' . join(', ', ('?') x @cols) . ')' . "\n";

    $class->profiler->record_query($sql);
    my $sth = $class->_execute($sql, \@bind);

    my $id = $class->attribute->{dbd}->last_insert_id($class->dbh, $sth);
    my $obj = $class->search($table, { $class->schema->schema_info->{$table}->{pk} => $id } )->first;

    $class->call_schema_trigger('post_insert', $table, $obj);

    $obj;
}

sub bulk_insert {
    my ($class, $table, $args) = @_;

    my $code = $class->attribute->{dbd}->can('bulk_insert') or die "dbd don't provide bulk_insert method";
    $code->($class, $table, $args);
}

sub update {
    my ($class, $table, $args, $where) = @_;

    $class->call_schema_trigger('pre_update', $table, $args);

    # deflate
    for my $col (keys %{$args}) {
        $args->{$col} = $class->schema->call_deflate($col, $args->{$col});
    }

    my (@set,@bind);
    for my $col (keys %{ $args }) {
        push @set, "$col = ?";
        push @bind, $class->schema->utf8_off($col, $args->{$col});
    }

    my $stmt = $class->resultset;
    $class->_add_where($stmt, $where);
    push @bind, @{ $stmt->bind };

    my $sql = "UPDATE $table SET " . join(', ', @set) . ' ' . $stmt->as_sql_where;

    $class->profiler->record_query($sql);
    $class->_execute($sql, \@bind);

    for my $col (@{$class->schema->schema_info->{$table}->{columns}}) {
        $stmt->add_select($col);
    }
    $stmt->from([$table]);
    my $row = $stmt->retrieve->first;

    $class->call_schema_trigger('post_update', $table, $row);

    return $row;
}

sub delete {
    my ($class, $table, $where) = @_;

    $class->call_schema_trigger('pre_delete', $table, $where);

    my $stmt = $class->resultset(
        {
            from   => [$table],
        }
    );

    $class->_add_where($stmt, $where);

    my $sql = "DELETE " . $stmt->as_sql;
    $class->profiler->record_query($sql);
    $class->_execute($sql, $stmt->bind);

    $class->call_schema_trigger('post_delete', $table);
}

*find_or_insert = \*find_or_create;

sub find_or_create {
    my ($class, $table, $args) = @_;
    my $row = $class->single($table, $args);
    return $row if $row;
    $row = $class->insert($table, $args);
    return $row;
}

sub _add_where {
    my ($class, $stmt, $where) = @_;
    for my $col (keys %{$where}) {
        $stmt->add_where($col => $where->{$col});
    }
}

sub _execute {
    my ($class, $stmt, $bind) = @_;

    my $sth = $class->dbh->prepare($stmt);
    $sth->execute(@{$bind});
   return $sth;
}

sub _close_sth {
    my ($class, $sth) = @_;
    $sth->finish;
    undef $sth;
}

1;

__END__
=head1 NAME

DBIx::Skinny - simple DBI wrapper/ORMapper

=head1 SYNOPSIS

    package Your::Model;
    use DBIx::Skinny setup => +{
        dsn => 'dbi:SQLite:',
        username => '',
        password => '',
    }
    1;
    
    package Your::Model::Schema;
    use DBIx::Skinny::Schema;
    
    install_table user => schema {
        pk 'id';
        columns qw/
            id
            name
        /;
    };
    1;
    
    # in your script:
    use Your::Model;
    
    # insert    
    my $row = Your::Model->insert('user',
        {
            id   => 1,
        }
    );
    $row->update('user',{name => 'nekokak'});

    $row = Your::Model->search_by_sql(q{SELECT id, name FROM user WHERE id = ?},1);
    $row->delete('user')

=head1 DESCRIPTION

DBIx::Skinny is simple DBI wrapper and simple O/R Mapper.

=head1 METHOD

=head2 insert

insert record

    my $row = Your::Model->insert('user',{
        id   => 1,
        name => 'nekokak',
    });

=head2 create

insert method alias.

=head2 update

update record

    Your::Model->update('user',{
        name => 'nomaneko',
    },{ id => 1 });

=head2 delete

delete record

    Your::Model->delete('user',{
        id => 1,
    });

=head2 find_or_create

create record if not exsists record

    my $row = Your::Model->find_or_create('usr',{
        id   => 1,
        name => 'nekokak',
    });

=head2 find_or_insert

find_or_create method alias.

=head2 search

simple search method.

get iterator:

    my $itr = Your::Model->search('user',{id => 1},{order_by => 'id'});

get rows:

    my @rows = Your::Model->search('user',{id => 1},{order_by => 'id'});

=head2 single

get one record

    my $row = Your::Model->single('user',{id =>1});

=head2 resultset

result set case:

    my $rs = Your::Model->resultset(
        select => [qw/id name/],
        from   => [qw/user/],
    );
    $rs->add_where('name' => {op => 'like', value => "%neko%"});
    $rs->limit(10);
    $rs->offset(10);
    $rs->order({ column => 'id', desc => 'DESC' });
    my $itr = $rs->retrieve;

=head2 count

get simple count

    my $cnt = Your::Model->count('user',{count => 'id'})->count;

=head2 search_by_sql

execute your SQL

    my $itr = Your::Model->search_by_sql(q{
        SELECT
            id, name
        FROM
            user
        WHERE
            id = ?
    },1);

=head2 do

execute your query.

=head2 dbh

get database handle.

=head1 BUGS AND LIMITATIONS

No bugs have been reported.

=head1 AUTHOR

Atsushi Kobayashi  C<< <nekokak __at__ gmail.com> >>

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2009, Atsushi Kobayashi C<< <nekokak __at__ gmail.com> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

