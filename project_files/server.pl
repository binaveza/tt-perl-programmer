#!/usr/bin/perl

use strict;
use warnings;
use HTTP::Daemon;
use HTTP::Status;
use DBI;

my $port = 8080;
my $d = HTTP::Daemon->new(LocalPort => $port) or die "Failed: $!";
print "Server running at http://localhost:$port/\n";
print "Press Ctrl+C to stop\n";

while (my $c = $d->accept) {
    while (my $r = $c->get_request) {
        my $uri = $r->uri;
        my $query = $uri->query || '';
        my $address = '';
        if ($query =~ /address=([^&]*)/) {
            $address = $1;
            $address =~ s/\+/ /g;
            $address =~ s/%([a-fA-F0-9]{2})/pack("C", hex($1))/eg;
        }
        $address =~ s/^\s+|\s+$//g;
        
        my $html = generate_html($address);
        $c->send_response(HTTP::Response->new(200, 'OK', 
            ['Content-Type' => 'text/html; charset=utf-8'], 
            $html));
    }
    $c->close;
}

sub generate_html {
    my $address = shift;
    
    my $html = qq{<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Mail Log Search</title>
    <style>
        body { font-family: Arial; max-width: 900px; margin: 20px; }
        input { width: 300px; padding: 8px; }
        button { padding: 8px 20px; cursor: pointer; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; }
        th { background: #333; color: white; padding: 8px; text-align: left; }
        td { padding: 8px; border-bottom: 1px solid #ddd; font-family: monospace; font-size: 13px; }
        .info { background: #e8f4fd; padding: 10px; margin: 10px 0; }
        .err { background: #f8d7da; padding: 10px; border: 1px solid #f5c6cb; margin: 10px 0; }
        .warn { background: #fff3cd; padding: 10px; border: 1px solid #ffc107; margin: 10px 0; }
    </style>
</head>
<body>
    <h2>Mail Log Search</h2>
    <form method="GET">
        <label>mail address:</label>
        <input type="text" name="address" placeholder="user\@domain.com" value="$address">
        <button type="submit">Search</button>
    </form>
};
    
    if ($address) {
        my $dbh = DBI->connect(
            "DBI:Pg:dbname=test_db;host=localhost;port=5432",
            'postgres',
            '1234',
            { RaiseError => 0, AutoCommit => 1, PrintError => 0 }
        );
        
        if ($dbh) {
            my $search = '%' . $address . '%';
            my $limit = 100;
            
            my $count = $dbh->prepare(q{
                SELECT COUNT(*) as total FROM (
                    SELECT str FROM message WHERE str ILIKE ?
                    UNION ALL
                    SELECT str FROM log WHERE address ILIKE ?
                ) AS t
            });
            $count->execute($search, $search);
            my $total = $count->fetchrow_hashref()->{total} || 0;
            $count->finish();
            
            if ($total == 0) {
                $html .= "<div class='err'>No results found for: $address</div>";
            } else {
                $html .= "<div class='info'>Found: $total records</div>";
                if ($total > $limit) {
                    $html .= "<div class='warn'>Showing first $limit records of $total</div>";
                }
                
                my $sth = $dbh->prepare(q{
                    SELECT * FROM (
                        SELECT created, str as log_line FROM message WHERE str ILIKE ?
                        UNION ALL
                        SELECT created, str as log_line FROM log WHERE address ILIKE ?
                    ) AS t
                    ORDER BY created
                    LIMIT ?
                });
                $sth->execute($search, $search, $limit);
                
                $html .= "<table><tr><th>Time</th><th>Log line</th></tr>";
                while (my $row = $sth->fetchrow_hashref()) {
                    $html .= "<tr><td>$row->{created}</td><td>$row->{log_line}</td></tr>";
                }
                $html .= "</table>";
                $sth->finish();
            }
            
            $dbh->disconnect();
        } else {
            $html .= "<div class='err'>Database connection failed</div>";
        }
    } else {
        $html .= "<div class='info'>Enter recipient address to search</div>";
    }
    
    $html .= "</body></html>";
    return $html;
}