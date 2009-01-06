package DBIx::Skinny::Row;
use strict;
use warnings;
use DBIx::Skinny::Accessor;
use Carp;

mk_accessors(qw/ row_data skinny select_columns opt_table_info /);

sub setup {
    my $self = shift;
    my $class = ref $self;

    $self->select_columns([keys %{$self->row_data}]);

    for my $alias ( @{$self->select_columns} ) {
        (my $col = lc $alias) =~ s/.+\.(.+)/$1/o;
        next if $class->can($col);
        no strict 'refs';
        *{"$class\::$col"} = $self->_razy_get_data($col);
    }
}

sub _razy_get_data {
    my ($self, $col) = @_;

    return sub {
        my $self = shift;

        my $data = $self->get_column($col);
        $self->skinny->schema->call_inflate($col, $data);
    };
}

sub get_column {
    my ($self, $col) = @_;

    my $data = $self->row_data->{$col};

    $data = $self->skinny->schema->utf8_on($col, $data);

    return $data;
}

sub get_columns {
    my $self = shift;

    my %data;
    for my $col ( @{$self->select_columns} ) {
        $data{$col} = $self->get_column($col);
    }
    return \%data;
}

sub update {
    my ($self, $args, $table) = @_;
    $table ||= $self->opt_table_info;
    my $where = $self->_update_or_delete_cond($table);
    $self->skinny->update($table, $args, $where);
}

sub delete {
    my ($self, $table) = @_;
    $table ||= $self->opt_table_info;
    my $where = $self->_update_or_delete_cond($table);
    $self->skinny->delete($table, $where);
}

sub _update_or_delete_cond {
    my ($self, $table) = @_;

    unless ($table) {
        croak "no table info";
    }

    my $schema_info = $self->skinny->schema->schema_info;
    unless ( $schema_info->{$table} ) {
        croak "unknown table: $table";
    }

    # get target table pk
    my $pk = $schema_info->{$table}->{pk};
    unless ($pk) {
        croak "$table have no pk.";
    }

    unless (grep { $pk eq $_ } @{$self->select_columns}) {
        croak "can't get primary column in your query.";
    }

    return +{ $pk => $self->$pk };
}

1;

