package main

import "testing"

func TestAdd(t *testing.T) { if add(2, 3) != 5 { t.Fatal("bad add") } }
