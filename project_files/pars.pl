#!/usr/bin/perl

use strict;
use warnings;
use DBI;
use Encode;

# --- DB Config ---
my %DB_CONFIG = (
    driver   => 'Pg',
    database => 'test_db',
    host     => 'localhost',
    port     => 5432,
    user     => 'postgres',
    password => '1234'  
);

# --- Settings ---
my $log_file = 'out';
my $debug = 0;  # Set to 1 for detailed output

# --- DB Connect ---
my $dsn = "DBI:$DB_CONFIG{driver}:dbname=$DB_CONFIG{database};host=$DB_CONFIG{host};port=$DB_CONFIG{port}";
my $dbh = DBI->connect($dsn, $DB_CONFIG{user}, $DB_CONFIG{password},
    { 
        RaiseError => 0,
        AutoCommit => 1,
        PrintError => 0,
        pg_enable_utf8 => 1
    }
) or die "Could not connect to database: $DBI::errstr";

print "Connected to database successfully.\n";

# --- SQL rules ---
my $insert_message = $dbh->prepare(
    "INSERT INTO message (created, id, int_id, str, status) 
     VALUES (?, ?, ?, ?, ?) 
     ON CONFLICT (id) DO NOTHING"
);

my $insert_log = $dbh->prepare(
    "INSERT INTO log (created, int_id, str, address) VALUES (?, ?, ?, ?)"
);

# --- Statistics ---
my $total_lines = 0;
my $message_count = 0;
my $log_count = 0;
my $error_count = 0;
my $duplicate_count = 0;
my $processed_count = 0;
my $empty_id_count = 0;

# --- Work with log file ---
open my $fh, '<:encoding(UTF-8)', $log_file or die "Could not open file '$log_file': $!";

print "=" x 80 . "\n";
print "Processing log file: $log_file\n";
print "Using ON CONFLICT DO NOTHING for message table\n";
print "=" x 80 . "\n\n";

while (my $line = <$fh>) {
    $total_lines++;
    chomp $line;
    $line =~ s/^\x{FEFF}//;
    next if $line =~ /^\s*$/;

    my %parsed = (
        timestamp => '',
        int_id => '',
        flag => '',
        address => '',
        other_info => '',
        id => '',
        rest_of_line => '',
        target_table => ''
    );

    # 1. Timestamp
    if ($line =~ /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(.*)$/) {
        $parsed{timestamp} = $1;
        my $rest_of_line = $2;
        $parsed{rest_of_line} = $rest_of_line;

        # 2. Internal ID
        if ($rest_of_line =~ /^([^\s]+)\s+(.*)$/) {
            $parsed{int_id} = $1;
            my $remaining = $2;

            # 3. Check flag '<='
            if ($remaining =~ /^<=\s+(.*)$/) {
                $parsed{flag} = '<=';
                $parsed{target_table} = 'message';
                my $after_flag = $1;
                
                # Extract address
                if ($after_flag =~ /^([^\s]+)\s+(.*)$/) {
                    $parsed{address} = $1;
                    $parsed{other_info} = $2;
                } else {
                    $parsed{address} = $after_flag;
                    $parsed{other_info} = '';
                }
                
                # Extract id from other_info
                if ($parsed{other_info} =~ /id=([^\s]+)/) {
                    $parsed{id} = $1;
                }
                
                # If id is empty or not found, generate a unique one
                if (!$parsed{id} || $parsed{id} eq '') {
                    $parsed{id} = 'msg_' . $parsed{timestamp} . '_' . $parsed{int_id};
                    $empty_id_count++;
                    if ($debug) {
                        print "  -> Generated ID for empty: $parsed{id}\n";
                    }
                }
                
                # Insert into message table with ON CONFLICT
                my $rows = $insert_message->execute(
                    $parsed{timestamp},
                    $parsed{id},
                    $parsed{int_id},
                    $parsed{rest_of_line},
                    undef
                );
                
                if (defined $rows) {
                    if ($rows == 1) {
                        $message_count++;
                        $processed_count++;
                        if ($debug) {
                            print "  -> Inserted into message (id: $parsed{id})\n";
                        }
                    } elsif ($rows == 0) {
                        $duplicate_count++;
                        if ($debug) {
                            print "  -> Duplicate skipped (id: $parsed{id})\n";
                        }
                    }
                } else {
                    $error_count++;
                    warn "Error inserting into message: " . $insert_message->errstr;
                    warn "  Line: $line";
                }
            }
            # Check for other flags: =>, ->, **, ==
            elsif ($remaining =~ /^(=>|->|\*\*|==)\s+(.*)$/) {
                $parsed{flag} = $1;
                $parsed{target_table} = 'log';
                my $after_flag = $2;
                
                # Extract address
                if ($after_flag =~ /^([^\s]+)\s+(.*)$/) {
                    $parsed{address} = $1;
                    $parsed{other_info} = $2;
                } else {
                    $parsed{address} = $after_flag;
                    $parsed{other_info} = '';
                }
                
                # Insert into log table
                my $rows = $insert_log->execute(
                    $parsed{timestamp},
                    $parsed{int_id},
                    $parsed{rest_of_line},
                    $parsed{address}
                );
                
                if (defined $rows) {
                    $log_count++;
                    $processed_count++;
                    if ($debug) {
                        print "  -> Inserted into log (address: $parsed{address})\n";
                    }
                } else {
                    $error_count++;
                    warn "Error inserting into log: " . $insert_log->errstr;
                    warn "  Line: $line";
                }
            }
            # No flag 
            else {
                $parsed{flag} = 'none';
                $parsed{target_table} = 'log';
                $parsed{other_info} = $remaining;
                $parsed{address} = '';
                
                # Insert into log table
                my $rows = $insert_log->execute(
                    $parsed{timestamp},
                    $parsed{int_id},
                    $parsed{rest_of_line},
                    undef
                );
                
                if (defined $rows) {
                    $log_count++;
                    $processed_count++;
                    if ($debug) {
                        print "  -> Inserted into log (no address)\n";
                    }
                } else {
                    $error_count++;
                    warn "Error inserting into log: " . $insert_log->errstr;
                    warn "  Line: $line";
                }
            }
        } else {
            $error_count++;
            warn "Line $total_lines: Could not parse int_id";
        }
    } else {
        $error_count++;
        warn "Line $total_lines: Could not parse timestamp";
    }
    
    # Progress 
    if ($total_lines % 1000 == 0) {
        print "Processed $total_lines lines... (inserted: $processed_count, duplicates: $duplicate_count, errors: $error_count)\n";
    }
}

close $fh;

# --- DB Disconnect ---
$insert_message->finish();
$insert_log->finish();
$dbh->disconnect();

# --- Summary log for CMD ---
print "\n" . "=" x 80 . "\n";
print "PROCESSING SUMMARY\n";
print "=" x 80 . "\n";
print "Total lines processed:   $total_lines\n";
print "Successfully inserted:\n";
print "  - Into message:        $message_count\n";
print "  - Into log:            $log_count\n";
print "  - Total inserted:      $processed_count\n";
print "Duplicates skipped:      $duplicate_count\n";
print "Generated IDs (empty):   $empty_id_count\n";
print "Errors:                  $error_count\n";
print "=" x 80 . "\n";

if ($error_count > 0) {
    print "\nWARNING: $error_count errors occurred during processing.\n";
    print "Check the error messages above for ditails.\n";
} else {
    print "\nAll lines processed successfully!\n";
}

print "Processing completed.\n";