#include <iostream>

struct Widget {
  int count;
  int color;
};

int add(int a, int b) { return a + b; }
int main() {
  Widget widget{};
  widget.color;
  std::cout << add(2, 3) << '\n';
}
